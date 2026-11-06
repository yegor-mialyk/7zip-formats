//
// HA 7-Zip Format
//
// Copyright (C) 2026, Yegor Mialyk. All Rights Reserved.
//
// Licensed under the GPL License. See the LICENSE file for details.
//

unit Ha.Hsc;

interface

uses
  Ha.Asc;

{$INCLUDE Compiler.pas}

function HscUnpack(const Read: THaReadFunc; const Write: THaWriteFunc;
  PackSize, UnpackSize: UInt64): THaResult;

implementation

const
  IECLIM = 32;    // initial escape counter upper limit
  NECLIM = 5;     // no escape expected counter limit
  NECTLIM = 4;
  NECMAX = 10;    // no escape expected counter maximum
  MAXCLEN = 4;    // assumed to be 4 in several places
  NUMCON = 10000; // number of contexts to remember
  NUMCFB = 32760; // number of frequencies to remember
  ESCTH = 3;      // threshold for escape calculation
  MAXTVAL = 8000; // maximum frequency value
  RFMINI = 4;     // initial refresh counter value
  HTLEN = 16384;  // length of hash table
  NilPtr = $FFFF; // NIL pointer in lists
  EscSym = 256;   // escape symbol

  IoBufSize = $10000;
  // The arithmetic decoder reads a few bits past the end of a valid stream
  MaxEofReads = 64;

type
  TContext = array [0..3] of Byte;

  // The first failure is stored in Res and is sticky: all the I/O routines
  // become no-ops once Res <> arOk
  THscDecoder = record
  private
    ReadFn: THaReadFunc;
    WriteFn: THaWriteFunc;
    Res: THaResult;
    PackLeft: UInt64;
    UnpackSize: UInt64;
    OutTotal: UInt64;
    EofReads: Integer;

    InBuf: TArray<Byte>;
    InPos, InLen: Integer;
    OutBuf: TArray<Byte>;
    OutLen: Integer;

    // Arithmetic decoder
    H, L, V: Word;
    Gpat: Integer;

    // Model data
    CurCon: TContext;                     // current context
    Ht: array [0..HTLEN - 1] of Word;     // hash table
    Hp: array [0..NUMCON - 1] of Word;    // hash list pointer array
    Con: array [0..NUMCON - 1] of TContext;
    Cl: array [0..NUMCON - 1] of Byte;    // context length array
    Cc: array [0..NUMCON - 1] of Byte;    // character counts
    Ft: array [0..NUMCON - 1] of Word;    // total frequency of context
    Fe: array [0..NUMCON - 1] of Byte;    // frequencies under ESCTH in context
    Elp: array [0..NUMCON - 1] of Word;   // expire list previous pointers
    Eln: array [0..NUMCON - 1] of Word;   // expire list next pointers
    Elf, Ell: Word;                       // first and last of expire list
    Rfm: array [0..NUMCON - 1] of Byte;   // refresh counter array
    Fa: array [0..NUMCFB - 1] of Word;    // frequency array
    Fc: array [0..NUMCFB - 1] of Byte;    // character for frequency array
    Nb: array [0..NUMCFB - 1] of Word;    // next pointer for frequency array
    Fcfbl: Word;                          // pointer to free frequency blocks
    Nrel: Word;                           // context for frequency block release

    // Frequency mask system
    Cmask: array [0..255] of Byte;        // masked characters
    Cmstack: array [0..255] of Byte;      // stack of Cmask entries to clear
    Cmsp: Integer;

    // Escape probability modifying system
    Nec: Byte;                            // counter for no escape expected
    Iec: array [0..MAXCLEN] of Byte;      // initial escape counters

    // Update stack
    Usp: Word;
    Cps: array [0..MAXCLEN + 1] of Word;  // context pointers
    Asx: array [0..MAXCLEN + 1] of Word;  // indexes to frequency array

    Dropcnt: SmallInt;                    // counter for context length drop
    CurMaxLen: Byte;                      // current maximum length for context
    Hrt: array [0..HTLEN - 1] of Word;    // semi random data for hashing
    Hs: array [0..MAXCLEN] of Word;       // hash stack for context search
    Cslen: Integer;                       // length of context to search

    procedure Fail(Code: THaResult);
    function NextByte: Integer;
    procedure FlushOut;
    procedure PutByte(C: Byte);

    procedure GetBit;
    procedure AcInit;
    procedure AcIn(Low, High, Tot: Word);
    function AcThreshold(Tot: Word): Word;

    procedure InitModel;
    function Hash(const S: TContext; Len: Integer): Integer;
    procedure ReleaseCfBlocks;
    function MakeContext(ConLen: Byte; C: Integer): Word;
    procedure ElMoveFront(Cp: Word);
    procedure AddModel(C: Integer);
    function FindNext: Word;
    function FindLongest: Word;
    function AdjEscapeProb(Esc: Word; Cp: Word): Word;
    function DecodeFirst(Cp: Word): Integer;
    function DecodeRest(Cp: Word): Integer;
    function DecodeNew: Integer;
    procedure Decode;
  end;
  PHscDecoder = ^THscDecoder;

procedure THscDecoder.Fail(Code: THaResult);
begin
  if Res = arOk then
    Res := Code;
end;

// Returns the next input byte or -1 at the end of data or on failure
function THscDecoder.NextByte: Integer;
var
  n: Integer;
  want: UInt64;
begin
  if Res <> arOk then
    Exit(-1);

  if InPos >= InLen then
  begin
    InPos := 0;
    InLen := 0;

    if PackLeft > 0 then
    begin
      want := IoBufSize;
      if want > PackLeft then
        want := PackLeft;

      n := ReadFn(InBuf[0], Integer(want));
      if n < 0 then
      begin
        Fail(arReadError);
        Exit(-1);
      end;
      if n > Integer(want) then
        n := Integer(want);

      InLen := n;
      Dec(PackLeft, n);
      // A short stream is treated as truncated
      if n = 0 then
        PackLeft := 0;
    end;

    if InLen = 0 then
    begin
      Inc(EofReads);
      if EofReads > MaxEofReads then
        Fail(arUnexpectedEnd);
      Exit(-1);
    end;
  end;

  Result := InBuf[InPos];
  Inc(InPos);
end;

procedure THscDecoder.FlushOut;
begin
  if (Res = arOk) and (OutLen > 0) then
  begin
    if not WriteFn(OutBuf[0], OutLen) then
      Fail(arWriteError);
    OutLen := 0;
  end;
end;

procedure THscDecoder.PutByte(C: Byte);
begin
  if Res <> arOk then
    Exit;

  if OutTotal >= UnpackSize then
  begin
    Fail(arDataError);
    Exit;
  end;

  OutBuf[OutLen] := C;
  Inc(OutLen);
  Inc(OutTotal);
  if OutLen = IoBufSize then
    FlushOut;
end;

{ Arithmetic decoder }

// Shifts the next stream bit into V
procedure THscDecoder.GetBit;
var
  c: Integer;
begin
  Gpat := Gpat shl 1;
  if (Gpat and $FF) = 0 then
  begin
    c := NextByte;
    if c < 0 then
      Gpat := $100
    else
      Gpat := (c shl 1) or 1;
  end;
  V := V or Word((Gpat and $100) shr 8);
end;

procedure THscDecoder.AcInit;
begin
  H := $FFFF;
  L := 0;
  Gpat := 0;
  V := Word(NextByte shl 8);
  V := V or Word(NextByte and $FF);
end;

procedure THscDecoder.AcIn(Low, High, Tot: Word);
var
  r: Cardinal;
begin
  if Res <> arOk then
    Exit;

  if Tot = 0 then
  begin
    Fail(arDataError);
    Exit;
  end;

  r := Cardinal(Integer(H) - Integer(L)) + 1;
  H := Word(r * High div Tot - 1) + L;
  L := L + Word(r * Low div Tot);

  while ((H xor L) and $8000) = 0 do
  begin
    L := Word(L shl 1);
    H := Word(H shl 1) or 1;
    V := Word(V shl 1);
    GetBit;
  end;

  while ((L and $4000) <> 0) and ((H and $4000) = 0) do
  begin
    L := Word(L shl 1) and $7FFF;
    H := Word(H shl 1) or $8001;
    V := Word(V shl 1);
    V := V xor $8000;
    GetBit;
  end;
end;

function THscDecoder.AcThreshold(Tot: Word): Word;
var
  r: Cardinal;
begin
  r := Cardinal(Integer(H) - Integer(L)) + 1;
  if r = 0 then
  begin
    Fail(arDataError);
    Exit(0);
  end;

  Result := Word(((Cardinal(Integer(V) - Integer(L)) + 1) * Tot - 1) div r);
end;

{ Model }

procedure THscDecoder.InitModel;
var
  i: Integer;
  z, lo, hi, t: Int64;
begin
  CurMaxLen := MAXCLEN;
  Iec[0] := IECLIM shr 1;
  for i := 1 to MAXCLEN do
    Iec[i] := (IECLIM shr 1) - 1;
  Dropcnt := NUMCON div 4;
  Nec := 0;
  Nrel := 0;
  Hs[0] := 0;

  for i := 0 to HTLEN - 1 do
    Ht[i] := NilPtr;

  for i := 0 to NUMCON - 1 do
  begin
    Eln[i] := Word(i + 1);
    Elp[i] := Word(i - 1);
    Cl[i] := $FF;
    Nb[i] := NilPtr;
  end;
  Elf := 0;
  Ell := NUMCON - 1;

  for i := NUMCON to NUMCFB - 2 do
    Nb[i] := Word(i + 1);
  Nb[NUMCFB - 1] := NilPtr;
  Fcfbl := NUMCON;

  FillChar(CurCon, SizeOf(CurCon), 0);
  Cmsp := 0;
  FillChar(Cmask, SizeOf(Cmask), 0);

  z := 10;
  for i := 0 to HTLEN - 1 do
  begin
    hi := z div (2147483647 div 16807);
    lo := z mod (2147483647 div 16807);
    t := 16807 * lo - (2147483647 mod 16807) * hi;
    if t > 0 then
      z := t
    else
      z := t + 2147483647;
    Hrt[i] := Word(z) and (HTLEN - 1);
  end;
end;

function THscDecoder.Hash(const S: TContext; Len: Integer): Integer;
begin
  Result := 0;
  if Len > 0 then
    Result := Hrt[S[0]];
  if Len > 1 then
    Result := Hrt[(S[1] + Result) and (HTLEN - 1)];
  if Len > 2 then
    Result := Hrt[(S[2] + Result) and (HTLEN - 1)];
  if Len > 3 then
    Result := Hrt[(S[3] + Result) and (HTLEN - 1)];
end;

procedure THscDecoder.ReleaseCfBlocks;
var
  i, j, d: Word;
  k: Integer;
  busy: Boolean;
begin
  repeat
    repeat
      Inc(Nrel);
      if Nrel = NUMCON then
        Nrel := 0;
    until Nb[Nrel] <> NilPtr;

    busy := False;
    for k := 0 to Usp do
      if (Cps[k] and $7FFF) = Nrel then
      begin
        busy := True;
        Break;
      end;
  until not busy;

  i := Nb[Nrel];
  d := Fa[Nrel];
  while i <> NilPtr do
  begin
    if Fa[i] < d then
      d := Fa[i];
    i := Nb[i];
  end;
  Inc(d);

  if Fa[Nrel] < d then
  begin
    i := Nb[Nrel];
    while (Fa[i] < d) and (Nb[i] <> NilPtr) do
      i := Nb[i];
    Fa[Nrel] := Fa[i];
    Fc[Nrel] := Fc[i];
    j := Nb[i];
    Nb[i] := Fcfbl;
    Fcfbl := Nb[Nrel];
    Nb[Nrel] := j;
    if j = NilPtr then
    begin
      Cc[Nrel] := 0;
      Ft[Nrel] := Fa[Nrel];
      if Ft[Nrel] < ESCTH then
        Fe[Nrel] := 1
      else
        Fe[Nrel] := 0;
      Exit;
    end;
  end;

  Fa[Nrel] := Fa[Nrel] div d;
  Ft[Nrel] := Fa[Nrel];
  if Ft[Nrel] < ESCTH then
    Fe[Nrel] := 1
  else
    Fe[Nrel] := 0;
  Cc[Nrel] := 0;

  j := Nrel;
  i := Nb[j];
  while i <> NilPtr do
  begin
    if Fa[i] < d then
    begin
      Nb[j] := Nb[i];
      Nb[i] := Fcfbl;
      Fcfbl := i;
      i := Nb[j];
    end
    else
    begin
      Inc(Cc[Nrel]);
      Fa[i] := Fa[i] div d;
      Inc(Ft[Nrel], Fa[i]);
      if Fa[i] < ESCTH then
        Inc(Fe[Nrel]);
      j := i;
      i := Nb[i];
    end;
  end;
end;

function THscDecoder.MakeContext(ConLen: Byte; C: Integer): Word;
var
  i: Integer;
  nc, fp: Word;
begin
  nc := Ell;
  Ell := Elp[nc];
  Elp[Elf] := nc;
  Eln[nc] := Elf;
  Elf := nc;

  if Cl[nc] <> $FF then
  begin
    if Cl[nc] = MAXCLEN then
    begin
      Dec(Dropcnt);
      if Dropcnt = 0 then
        CurMaxLen := MAXCLEN - 1;
    end;

    i := Hash(Con[nc], Cl[nc]);
    if Ht[i] = nc then
      Ht[i] := Hp[nc]
    else
    begin
      i := Ht[i];
      while Hp[i] <> nc do
        i := Hp[i];
      Hp[i] := Hp[nc];
    end;

    if Nb[nc] <> NilPtr then
    begin
      fp := Nb[nc];
      while Nb[fp] <> NilPtr do
        fp := Nb[fp];
      Nb[fp] := Fcfbl;
      Fcfbl := Nb[nc];
    end;
  end;

  Nb[nc] := NilPtr;
  Fa[nc] := 1;
  Ft[nc] := 1;
  Fe[nc] := 1;
  Fc[nc] := Byte(C);
  Rfm[nc] := RFMINI;
  Cc[nc] := 0;
  Cl[nc] := ConLen;
  Con[nc] := CurCon;
  i := Hash(CurCon, ConLen);
  Hp[nc] := Ht[i];
  Ht[i] := nc;
  Result := nc;
end;

procedure THscDecoder.ElMoveFront(Cp: Word);
begin
  if Cp = Elf then
    Exit;

  if Cp = Ell then
    Ell := Elp[Cp]
  else
  begin
    Elp[Eln[Cp]] := Elp[Cp];
    Eln[Elp[Cp]] := Eln[Cp];
  end;
  Elp[Elf] := Cp;
  Eln[Cp] := Elf;
  Elf := Cp;
end;

procedure THscDecoder.AddModel(C: Integer);
var
  i: Word;
  cp: Integer;
begin
  while Usp <> 0 do
  begin
    Dec(Usp);
    i := Asx[Usp];
    cp := Cps[Usp];

    if (cp and $8000) <> 0 then
    begin
      cp := cp and $7FFF;
      if Fcfbl = NilPtr then
        ReleaseCfBlocks;
      Nb[i] := Fcfbl;
      i := Fcfbl;
      Fcfbl := Nb[i];
      Nb[i] := NilPtr;
      Fa[i] := 1;
      Fc[i] := Byte(C);
      Inc(Cc[cp]);
      Inc(Fe[cp]);
    end
    else
    begin
      Inc(Fa[i]);
      if Fa[i] = ESCTH then
        Dec(Fe[cp]);
    end;

    Inc(Ft[cp]);
    if (Integer(Fa[i]) shl 1) < Integer(Ft[cp]) div (Integer(Cc[cp]) + 1) then
      Dec(Rfm[cp])
    else if Rfm[cp] < RFMINI then
      Inc(Rfm[cp]);

    if (Rfm[cp] = 0) or (Ft[cp] >= MAXTVAL) then
    begin
      Inc(Rfm[cp]);
      Fe[cp] := 0;
      Ft[cp] := 0;
      i := cp;
      while i <> NilPtr do
      begin
        if Fa[i] > 1 then
        begin
          Fa[i] := Fa[i] shr 1;
          Inc(Ft[cp], Fa[i]);
          if Fa[i] < ESCTH then
            Inc(Fe[cp]);
        end
        else
        begin
          Inc(Ft[cp]);
          Inc(Fe[cp]);
        end;
        i := Nb[i];
      end;
    end;
  end;
end;

function THscDecoder.FindNext: Word;
var
  i, j: Integer;
  cp: Word;
  ok: Boolean;
begin
  for i := Cslen - 1 downto 0 do
  begin
    cp := Ht[Hs[i]];
    while cp <> NilPtr do
    begin
      if Cl[cp] = i then
      begin
        ok := True;
        for j := 0 to i - 1 do
          if CurCon[j] <> Con[cp][j] then
          begin
            ok := False;
            Break;
          end;
        if ok then
        begin
          Cslen := i;
          Exit(cp);
        end;
      end;
      cp := Hp[cp];
    end;
  end;
  Result := NilPtr;
end;

function THscDecoder.FindLongest: Word;
begin
  Hs[1] := Hrt[CurCon[0]];
  Hs[2] := Hrt[(CurCon[1] + Hs[1]) and (HTLEN - 1)];
  Hs[3] := Hrt[(CurCon[2] + Hs[2]) and (HTLEN - 1)];
  Hs[4] := Hrt[(CurCon[3] + Hs[3]) and (HTLEN - 1)];
  Usp := 0;
  while Cmsp <> 0 do
  begin
    Dec(Cmsp);
    Cmask[Cmstack[Cmsp]] := 0;
  end;
  Cslen := MAXCLEN + 1;
  Result := FindNext;
end;

function THscDecoder.AdjEscapeProb(Esc: Word; Cp: Word): Word;
var
  cnt: Integer;
begin
  if Ft[Cp] = 1 then
  begin
    if Iec[Cl[Cp]] >= (IECLIM shr 1) then
      Exit(2)
    else
      Exit(1);
  end;

  if Cc[Cp] = 255 then
    Exit(1);

  cnt := Integer(Cc[Cp]) + 1;
  if (Cc[Cp] <> 0) and ((cnt shl 1) >= Ft[Cp]) then
  begin
    Esc := Word(Int64(Esc) * (cnt shl 1) div Ft[Cp]);
    if cnt = Ft[Cp] then
      Inc(Esc, cnt shr 1);
  end;

  if Esc <> 0 then
    Result := Esc
  else
    Result := 1;
end;

function THscDecoder.DecodeFirst(Cp: Word): Integer;
var
  c, tv, i, sum, tot, esc, cf, sv: Integer;
begin
  esc := AdjEscapeProb(Fe[Cp], Cp);
  tot := Ft[Cp];
  cf := 0;
  sum := 0;
  c := Cp;

  if Nec >= NECLIM then
  begin
    if (tot <= NECTLIM) and (Nec = NECMAX) then
      sv := 2
    else
      sv := 1;
    tot := tot shl sv;
    tv := AcThreshold(Word(tot + esc)) shr sv;
    while c <> NilPtr do
    begin
      if sum + Fa[c] <= tv then
      begin
        Inc(sum, Fa[c]);
        c := Nb[c];
      end
      else
      begin
        cf := Fa[c] shl sv;
        Break;
      end;
    end;
    sum := sum shl sv;
  end
  else
  begin
    tv := AcThreshold(Word(tot + esc));
    while c <> NilPtr do
    begin
      if sum + Fa[c] <= tv then
      begin
        Inc(sum, Fa[c]);
        c := Nb[c];
      end
      else
      begin
        cf := Fa[c];
        Break;
      end;
    end;
  end;

  Usp := 1;
  if c <> NilPtr then
  begin
    AcIn(Word(sum), Word(sum + cf), Word(tot + esc));
    if (Ft[Cp] = 1) and (Iec[Cl[Cp]] <> 0) then
      Dec(Iec[Cl[Cp]]);
    Asx[0] := c;
    Cps[0] := Cp;
    Result := Fc[c];
    if Nec < NECMAX then
      Inc(Nec);
  end
  else
  begin
    AcIn(Word(tot), Word(tot + esc), Word(tot + esc));
    if (Ft[Cp] = 1) and (Iec[Cl[Cp]] < IECLIM) then
      Inc(Iec[Cl[Cp]]);

    i := Cp;
    while i <> NilPtr do
    begin
      Cmstack[Cmsp] := Fc[i];
      Inc(Cmsp);
      Cmask[Fc[i]] := 1;
      sum := i;
      i := Nb[i];
    end;
    Cps[0] := $8000 or Cp;
    Asx[0] := sum;
    Result := EscSym;
    Nec := 0;
  end;
end;

function THscDecoder.DecodeRest(Cp: Word): Integer;
var
  c, tv, i, sum, tot, cf: Integer;
  esc: Word;
begin
  esc := 0;
  tot := 0;
  i := Cp;
  while i <> NilPtr do
  begin
    if Cmask[Fc[i]] = 0 then
    begin
      Inc(tot, Fa[i]);
      if Fa[i] < ESCTH then
        Inc(esc);
    end;
    i := Nb[i];
  end;

  esc := AdjEscapeProb(esc, Cp);
  tv := AcThreshold(Word(tot + esc));
  cf := 0;
  sum := 0;
  c := Cp;
  while c <> NilPtr do
  begin
    if Cmask[Fc[c]] = 0 then
    begin
      if sum + Fa[c] <= tv then
        Inc(sum, Fa[c])
      else
      begin
        cf := Fa[c];
        Break;
      end;
    end;
    c := Nb[c];
  end;

  if c <> NilPtr then
  begin
    AcIn(Word(sum), Word(sum + cf), Word(tot + esc));
    if (Ft[Cp] = 1) and (Iec[Cl[Cp]] <> 0) then
      Dec(Iec[Cl[Cp]]);
    Asx[Usp] := c;
    Cps[Usp] := Cp;
    Inc(Usp);
    Result := Fc[c];
    Inc(Nec);
  end
  else
  begin
    AcIn(Word(tot), Word(tot + esc), Word(tot + esc));
    if (Ft[Cp] = 1) and (Iec[Cl[Cp]] < IECLIM) then
      Inc(Iec[Cl[Cp]]);

    i := Cp;
    while i <> NilPtr do
    begin
      if Cmask[Fc[i]] = 0 then
      begin
        Cmstack[Cmsp] := Fc[i];
        Inc(Cmsp);
        Cmask[Fc[i]] := 1;
      end;
      sum := i;
      i := Nb[i];
    end;
    Cps[Usp] := $8000 or Cp;
    Asx[Usp] := sum;
    Inc(Usp);
    Result := EscSym;
  end;
end;

function THscDecoder.DecodeNew: Integer;
var
  c, sum, tot, tv: Integer;
begin
  tot := 257 - Cmsp;
  tv := AcThreshold(Word(tot));
  sum := 0;
  c := 0;
  while c < 256 do
  begin
    if Cmask[c] = 0 then
    begin
      if sum + 1 <= tv then
        Inc(sum)
      else
        Break;
    end;
    Inc(c);
  end;
  AcIn(Word(sum), Word(sum + 1), Word(tot));
  Result := c;
end;

procedure THscDecoder.Decode;
var
  c: Integer;
  cp: Word;
  ncmax, ncmin: Byte;
begin
  InitModel;
  AcInit;

  while Res = arOk do
  begin
    cp := FindLongest;
    if cp = NilPtr then
      ncmin := 0
    else
      ncmin := Cl[cp] + 1;
    ncmax := CurMaxLen + 1;

    while True do
    begin
      if cp = NilPtr then
      begin
        c := DecodeNew;
        Break;
      end;

      if Cmsp <> 0 then
        c := DecodeRest(cp)
      else
        c := DecodeFirst(cp);
      if c <> EscSym then
      begin
        ElMoveFront(cp);
        Break;
      end;

      cp := FindNext;
    end;

    if c = EscSym then
      Break;

    AddModel(c);
    while ncmax > ncmin do
    begin
      Dec(ncmax);
      MakeContext(ncmax, c);
    end;
    PutByte(Byte(c));
    CurCon[3] := CurCon[2];
    CurCon[2] := CurCon[1];
    CurCon[1] := CurCon[0];
    CurCon[0] := Byte(c);
  end;

  FlushOut;
  if (Res = arOk) and (OutTotal <> UnpackSize) then
    Fail(arDataError);
end;

function HscUnpack(const Read: THaReadFunc; const Write: THaWriteFunc;
  PackSize, UnpackSize: UInt64): THaResult;
var
  dec: PHscDecoder;
begin
  GetMem(dec, SizeOf(THscDecoder));
  dec.ReadFn := Read;
  dec.WriteFn := Write;
  dec.PackLeft := PackSize;
  dec.UnpackSize := UnpackSize;
  SetLength(dec.InBuf, IoBufSize);
  SetLength(dec.OutBuf, IoBufSize);

  dec.Decode;

  Result := dec.Res;

  FreeMem(dec);
end;

end.
