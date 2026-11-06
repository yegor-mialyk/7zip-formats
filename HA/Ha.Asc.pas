//
// HA 7-Zip Format
//
// Copyright (C) 2026, Yegor Mialyk. All Rights Reserved.
//
// Licensed under the GPL License. See the LICENSE file for details.
//

unit Ha.Asc;

interface

{$INCLUDE Compiler.pas}

type
  THaReadFunc = reference to function(var Buf; Size: Integer): Integer;
  THaWriteFunc = reference to function(const Buf; Size: Integer): Boolean;

  THaResult = (arOk, arDataError, arUnexpectedEnd, arReadError, arWriteError);

function AscUnpack(const Read: THaReadFunc; const Write: THaWriteFunc;
  PackSize, UnpackSize: UInt64): THaResult;

implementation

const
  POSCODES = 31200;
  SLCODES = 16;
  LLCODES = 48;
  LLLEN = 16;
  LLBITS = 4;
  LENCODES = SLCODES + LLCODES * LLLEN;
  LTCODES = SLCODES + LLCODES;
  CTCODES = 256;
  PTCODES = 16;
  LTSTEP = 8;
  MAXLT = 750 * LTSTEP;
  CTSTEP = 1;
  MAXCT = 1000 * CTSTEP;
  PTSTEP = 24;
  MAXPT = 250 * PTSTEP;
  TTSTEP = 40;
  MAXTT = 150 * TTSTEP;
  TTORD = 4;
  TTOMASK = TTORD - 1;
  LCUTOFF = 3 * LTSTEP;
  CCUTOFF = 3 * CTSTEP;
  CPLEN = 8;
  LPLEN = 4;
  MINLEN = 3;

  IoBufSize = $10000;
  // The arithmetic decoder reads a few bits past the end of a valid stream
  MaxEofReads = 64;

type
  TWordArray = array [0..2 * CTCODES - 1] of Word;
  PWordArray = ^TWordArray;

  // The first failure is stored in Res and is sticky: all the routines
  // become no-ops once Res <> arOk
  TAscDecoder = record
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

    // Sliding window
    Win: TArray<Byte>;
    WinPos: Integer;

    // Arithmetic decoder
    H, L, V: Word;
    Gpat: Integer;

    // Model
    Ltab: array [0..2 * LTCODES - 1] of Word;
    Eltab: array [0..2 * LTCODES - 1] of Word;
    Ptab: array [0..2 * PTCODES - 1] of Word;
    Ctab: array [0..2 * CTCODES - 1] of Word;
    Ectab: array [0..2 * CTCODES - 1] of Word;
    Ttab: array [0..TTORD - 1, 0..1] of Word;
    Ccnt, Pmax, Npt: Word;
    Ces, Les: Word;
    Ttcon: Word;

    procedure Fail(Code: THaResult);
    procedure TabInit(T: PWordArray; Tl, IVal: Word);
    procedure TScale(T: PWordArray; Tl: Word);
    procedure TUpd(T: PWordArray; Tl, MaxT, Step, P: Word);
    procedure TZero(T: PWordArray; Tl, P: Word);
    function TSearch(T: PWordArray; Tl, Tv: Word; out Lt: Word): Word;
    function NextByte: Integer;
    procedure GetBit(var B: Word); inline;
    procedure AcInit;
    procedure AcIn(Low, High, Tot: Word);
    function AcThreshold(Tot: Word): Word;
    procedure FlushOut;
    procedure PutByte(C: Byte); inline;
    procedure DChar(C: Byte);
    procedure DPair(L, P: Word);
    procedure TtScale(Con: Word);
    procedure ModelInit;
    procedure Decode;
  end;

procedure TAscDecoder.Fail(Code: THaResult);
begin
  if Res = arOk then
    Res := Code;
end;

procedure TAscDecoder.TabInit(T: PWordArray; Tl, IVal: Word);
var
  i, j: Integer;
begin
  for i := Tl to 2 * Tl - 1 do
    T[i] := IVal;

  i := Tl - 1;
  j := (Tl shl 1) - 2;
  while i <> 0 do
  begin
    T[i] := T[j] + T[j + 1];
    Dec(i);
    Dec(j, 2);
  end;
end;

procedure TAscDecoder.TScale(T: PWordArray; Tl: Word);
var
  i, j: Integer;
begin
  for i := (Tl shl 1) - 1 downto Tl do
    if T[i] > 1 then
      T[i] := T[i] shr 1;

  i := Tl - 1;
  j := (Tl shl 1) - 2;
  while i <> 0 do
  begin
    T[i] := T[j] + T[j + 1];
    Dec(i);
    Dec(j, 2);
  end;
end;

procedure TAscDecoder.TUpd(T: PWordArray; Tl, MaxT, Step, P: Word);
var
  i: Integer;
begin
  i := P + Tl;
  while i <> 0 do
  begin
    T[i] := T[i] + Step;
    i := i shr 1;
  end;

  if T[1] >= MaxT then
    TScale(T, Tl);
end;

procedure TAscDecoder.TZero(T: PWordArray; Tl, P: Word);
var
  i: Integer;
  step: Word;
begin
  i := P + Tl;
  step := T[i];
  while i <> 0 do
  begin
    T[i] := T[i] - step;
    i := i shr 1;
  end;
end;

// Finds the symbol whose cumulative frequency range contains Tv
function TAscDecoder.TSearch(T: PWordArray; Tl, Tv: Word; out Lt: Word): Word;
var
  l: Integer;
begin
  l := 2;
  Lt := 0;
  while True do
  begin
    if Lt + T[l] <= Tv then
    begin
      Lt := Lt + T[l];
      Inc(l);
    end;
    if l >= Tl then
    begin
      Dec(l, Tl);
      Break;
    end;
    l := l shl 1;
  end;
  Result := l;
end;

// Returns the next input byte or -1 at the end of data or on failure
function TAscDecoder.NextByte: Integer;
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

procedure TAscDecoder.GetBit(var B: Word);
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
  B := B or Word((Gpat and $100) shr 8);
end;

procedure TAscDecoder.AcInit;
begin
  H := $FFFF;
  L := 0;
  Gpat := 0;
  V := Word(NextByte shl 8);
  V := V or Word(NextByte and $FF);
end;

procedure TAscDecoder.AcIn(Low, High, Tot: Word);
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
    GetBit(V);
  end;

  while ((L and $4000) <> 0) and ((H and $4000) = 0) do
  begin
    L := Word(L shl 1) and $7FFF;
    H := Word(H shl 1) or $8001;
    V := Word(V shl 1);
    V := V xor $8000;
    GetBit(V);
  end;
end;

function TAscDecoder.AcThreshold(Tot: Word): Word;
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

procedure TAscDecoder.FlushOut;
begin
  if (Res = arOk) and (OutLen > 0) then
  begin
    if not WriteFn(OutBuf[0], OutLen) then
      Fail(arWriteError);
    OutLen := 0;
  end;
end;

procedure TAscDecoder.PutByte(C: Byte);
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

procedure TAscDecoder.DChar(C: Byte);
begin
  Win[WinPos] := C;
  PutByte(C);
  Inc(WinPos);
  if WinPos = POSCODES then
    WinPos := 0;
end;

procedure TAscDecoder.DPair(L, P: Word);
var
  src: Integer;
begin
  if P >= POSCODES then
  begin
    Fail(arDataError);
    Exit;
  end;

  if WinPos > P then
    src := WinPos - 1 - P
  else
    src := POSCODES - 1 - P + WinPos;

  while L > 0 do
  begin
    Win[WinPos] := Win[src];
    PutByte(Win[src]);
    Inc(WinPos);
    if WinPos = POSCODES then
      WinPos := 0;
    Inc(src);
    if src = POSCODES then
      src := 0;
    Dec(L);
  end;
end;

procedure TAscDecoder.TtScale(Con: Word);
begin
  Ttab[Con][0] := Ttab[Con][0] shr 1;
  if Ttab[Con][0] = 0 then
    Ttab[Con][0] := 1;
  Ttab[Con][1] := Ttab[Con][1] shr 1;
  if Ttab[Con][1] = 0 then
    Ttab[Con][1] := 1;
end;

procedure TAscDecoder.ModelInit;
var
  i: Integer;
begin
  Ces := CTSTEP;
  Les := LTSTEP;
  Ccnt := 0;
  Ttcon := 0;
  Npt := 1;
  Pmax := 1;
  for i := 0 to TTORD - 1 do
  begin
    Ttab[i][0] := TTSTEP;
    Ttab[i][1] := TTSTEP;
  end;
  TabInit(@Ltab, LTCODES, 0);
  TabInit(@Eltab, LTCODES, 1);
  TabInit(@Ctab, CTCODES, 0);
  TabInit(@Ectab, CTCODES, 1);
  TabInit(@Ptab, PTCODES, 0);
  TUpd(@Ptab, PTCODES, MAXPT, PTSTEP, 0);
end;

procedure TAscDecoder.Decode;
var
  l, p, tv, i, lt: Word;
  stop: Word;
begin
  WinPos := 0;
  ModelInit;
  AcInit;

  while Res = arOk do
  begin
    tv := AcThreshold(Ttab[Ttcon][0] + Ttab[Ttcon][1] + 1);
    i := Ttab[Ttcon][0] + Ttab[Ttcon][1];

    if Ttab[Ttcon][0] > tv then
    begin
      // Literal
      AcIn(0, Ttab[Ttcon][0], i + 1);
      Ttab[Ttcon][0] := Ttab[Ttcon][0] + TTSTEP;
      if i >= MAXTT then
        TtScale(Ttcon);
      Ttcon := (Ttcon shl 1) and TTOMASK;

      tv := AcThreshold(Ctab[1] + Ces);
      if tv >= Ctab[1] then
      begin
        AcIn(Ctab[1], Ctab[1] + Ces, Ctab[1] + Ces);
        tv := AcThreshold(Ectab[1]);
        l := TSearch(@Ectab, CTCODES, tv, lt);
        AcIn(lt, lt + Ectab[CTCODES + l], Ectab[1]);
        TZero(@Ectab, CTCODES, l);
        if Ectab[1] <> 0 then
          Ces := Ces + CTSTEP
        else
          Ces := 0;

        if l < CPLEN then
          i := 0
        else
          i := l - CPLEN;
        if l + CPLEN >= CTCODES - 1 then
          stop := CTCODES - 1
        else
          stop := l + CPLEN;
        while i < stop do
        begin
          if Ectab[CTCODES + i] <> 0 then
            TUpd(@Ectab, CTCODES, MAXCT, 1, i);
          Inc(i);
        end;
      end
      else
      begin
        l := TSearch(@Ctab, CTCODES, tv, lt);
        AcIn(lt, lt + Ctab[CTCODES + l], Ctab[1] + Ces);
      end;

      TUpd(@Ctab, CTCODES, MAXCT, CTSTEP, l);
      if Ctab[CTCODES + l] = CCUTOFF then
        if CTSTEP < Ces then
          Ces := Ces - CTSTEP
        else
          Ces := Ces - (Ces - 1);

      DChar(l);
      if Ccnt < POSCODES then
        Inc(Ccnt);
    end
    else if i > tv then
    begin
      // Match
      AcIn(Ttab[Ttcon][0], i, i + 1);
      Ttab[Ttcon][1] := Ttab[Ttcon][1] + TTSTEP;
      if i >= MAXTT then
        TtScale(Ttcon);
      Ttcon := ((Ttcon shl 1) or 1) and TTOMASK;

      while Ccnt > Pmax do
      begin
        TUpd(@Ptab, PTCODES, MAXPT, PTSTEP, Npt);
        Inc(Npt);
        Pmax := Pmax shl 1;
      end;

      tv := AcThreshold(Ptab[1]);
      p := TSearch(@Ptab, PTCODES, tv, lt);
      AcIn(lt, lt + Ptab[PTCODES + p], Ptab[1]);
      TUpd(@Ptab, PTCODES, MAXPT, PTSTEP, p);
      if p > 1 then
      begin
        i := 1;
        while p <> 0 do
        begin
          i := i shl 1;
          Dec(p);
        end;
        i := i shr 1;

        if i = (Pmax shr 1) then
          l := Ccnt - (Pmax shr 1)
        else
          l := i;
        p := AcThreshold(l);
        AcIn(p, p + 1, l);
        p := p + i;
      end;

      tv := AcThreshold(Ltab[1] + Les);
      if tv >= Ltab[1] then
      begin
        AcIn(Ltab[1], Ltab[1] + Les, Ltab[1] + Les);
        tv := AcThreshold(Eltab[1]);
        l := TSearch(@Eltab, LTCODES, tv, lt);
        AcIn(lt, lt + Eltab[LTCODES + l], Eltab[1]);
        TZero(@Eltab, LTCODES, l);
        if Eltab[1] <> 0 then
          Les := Les + LTSTEP
        else
          Les := 0;

        if l < LPLEN then
          i := 0
        else
          i := l - LPLEN;
        if l + LPLEN >= LTCODES - 1 then
          stop := LTCODES - 1
        else
          stop := l + LPLEN;
        while i < stop do
        begin
          if Eltab[LTCODES + i] <> 0 then
            TUpd(@Eltab, LTCODES, MAXLT, 1, i);
          Inc(i);
        end;
      end
      else
      begin
        l := TSearch(@Ltab, LTCODES, tv, lt);
        AcIn(lt, lt + Ltab[LTCODES + l], Ltab[1] + Les);
      end;

      TUpd(@Ltab, LTCODES, MAXLT, LTSTEP, l);
      if Ltab[LTCODES + l] = LCUTOFF then
        if LTSTEP < Les then
          Les := Les - LTSTEP
        else
          Les := Les - (Les - 1);

      if l = SLCODES - 1 then
        l := LENCODES - 1
      else if l >= SLCODES then
      begin
        i := AcThreshold(LLLEN);
        AcIn(i, i + 1, LLLEN);
        l := ((l - SLCODES) shl LLBITS) + i + SLCODES - 1;
      end;
      l := l + MINLEN;

      if Ccnt < POSCODES then
      begin
        Ccnt := Ccnt + l;
        if Ccnt > POSCODES then
          Ccnt := POSCODES;
      end;

      DPair(l, p);
    end
    else
    begin
      // End of data
      AcIn(i, i + 1, i + 1);
      Break;
    end;
  end;

  FlushOut;
  if (Res = arOk) and (OutTotal <> UnpackSize) then
    Fail(arDataError);
end;

function AscUnpack(const Read: THaReadFunc; const Write: THaWriteFunc;
  PackSize, UnpackSize: UInt64): THaResult;
var
  s: TAscDecoder;
begin
  s := Default(TAscDecoder);
  s.ReadFn := Read;
  s.WriteFn := Write;
  s.PackLeft := PackSize;
  s.UnpackSize := UnpackSize;
  SetLength(s.InBuf, IoBufSize);
  SetLength(s.OutBuf, IoBufSize);
  SetLength(s.Win, POSCODES);

  s.Decode;

  Result := s.Res;
end;

end.
