//
// HA 7-Zip Format
//
// Copyright (C) 2026, Yegor Mialyk. All Rights Reserved.
//
// Licensed under the GPL License. See the LICENSE file for details.
//

const
  HaSignature: array [0..1] of Byte = (Ord('H'), Ord('A'));

  HaMethodCpy = 0;
  HaMethodAsc = 1;
  HaMethodHsc = 2;
  HaMethodDir = 14;
  HaMethodSpecial = 15;

  HaDeletedMark = $FF;
  HaVersion = 2;
  HaFixedHeaderSize = 17;
  HaHeaderBufSize = 4096;
  HaCopyBufSize = $10000;
  HaMachineMsDos = 1;

  FileAttributeArchive = $20;
  FileAttributeDirectory = $10;

  kpvErrorFlagsHeadersError = UInt32(1) shl 1;
  kpvErrorFlagsUnexpectedEnd = UInt32(1) shl 5;

  PropIds: array [0..7] of PROPID = (
    kpidPath, kpidIsDir, kpidSize, kpidPackSize, kpidMTime, kpidAttrib, kpidCRC, kpidMethod
  );
  PropTypes: array [0..7] of TVarType = (
    VT_BSTR, VT_BOOL, VT_UI8, VT_UI8, VT_FILETIME, VT_UI4, VT_UI4, VT_BSTR
  );

type
  THaItem = record
    Path: string;
    Method: Byte;
    Attrib: UInt32;
    Size: UInt64;
    PackSize: UInt64;
    Crc: UInt32;
    Time: FILETIME;
    DataPos: UInt64;
  end;

  THaArchive = class(TInterfacedObject, IInArchive)
  private
    FStream: IInStream;
    FItems: array of THaItem;
    FPhySize: UInt64;
    FErrorFlags: UInt32;

    function ReadAt(pos: UInt64; var buf; size: UInt32): UInt32;
    function ParseItem(pos, arcSize: UInt64; out item: THaItem; out deleted: Boolean; out nextPos: UInt64): Boolean;
    function UnpackItem(const item: THaItem; outStream: ISequentialOutStream; callback: IArchiveExtractCallback;
      var done: UInt64; out opRes: Integer): HRESULT;
    function CopyItem(const item: THaItem; outStream: ISequentialOutStream; callback: IArchiveExtractCallback;
      var done: UInt64; out opRes: Integer): HRESULT;
  public
    function Open(stream: IInStream; const maxCheckStartPosition: PUInt64; openArchiveCallback: IArchiveOpenCallback): HRESULT; stdcall;
    function Close: HRESULT; stdcall;
    function GetNumberOfItems(out numItems: UInt32): HRESULT; stdcall;
    function GetProperty(index: UInt32; propID: PROPID; out value: PROPVARIANT): HRESULT; stdcall;
    function Extract(const indices: PUInt32; numItems: UInt32; testMode: Integer; extractCallback: IArchiveExtractCallback): HRESULT; stdcall;
    function GetArchiveProperty(propID: PROPID; out value: PROPVARIANT): HRESULT; stdcall;
    function GetNumberOfProperties(out numProperties: UInt32): HRESULT; stdcall;
    function GetPropertyInfo(index: UInt32; out name: TBStr; out propID: PROPID; out varType: TVarType): HRESULT; stdcall;
    function GetNumberOfArchiveProperties(out numProperties: UInt32): HRESULT; stdcall;
    function GetArchivePropertyInfo(index: UInt32; out name: TBStr; out propID: PROPID; out varType: TVarType): HRESULT; stdcall;
  end;

var
  Crc32Table: array [0..255] of UInt32;
  Crc32TableReady: Boolean = False;

procedure InitCrc32Table;
var
  i, j: Integer;
  v: UInt32;
begin
  if Crc32TableReady then
    Exit;

  for i := 0 to 255 do
  begin
    v := i;
    for j := 1 to 8 do
      if (v and 1) <> 0 then
        v := (v shr 1) xor $EDB88320
      else
        v := v shr 1;
    Crc32Table[i] := v;
  end;

  Crc32TableReady := True;
end;

function UpdateCrc32(crc: UInt32; const buf: PByte; size: UInt32): UInt32;
var
  p: PByte;
  i: UInt32;
begin
  Result := crc;
  p := buf;
  for i := 1 to size do
  begin
    Result := Crc32Table[(Result xor p^) and $FF] xor (Result shr 8);
    Inc(p);
  end;
end;

procedure UnixTimeToFileTime(t: UInt32; out ft: FILETIME);
var
  v: UInt64;
begin
  v := UInt64(t) * UInt64(10000000) + UInt64(116444736000000000);
  ft.dwLowDateTime := UInt32(v and $FFFFFFFF);
  ft.dwHighDateTime := UInt32(v shr 32);
end;

function GetUInt32(const p: PByte): UInt32; inline;
begin
  Result := UInt32(p[0]) or (UInt32(p[1]) shl 8) or (UInt32(p[2]) shl 16) or (UInt32(p[3]) shl 24);
end;

// HA stores directory separators as $FF and names in the DOS (OEM) code page
function DecodeHaPath(const p: PByte; len: Integer): string;
var
  bytes: array of Byte;
  i, n: Integer;
begin
  Result := '';
  if len <= 0 then
    Exit;

  SetLength(bytes, len);
  for i := 0 to len - 1 do
    if p[i] = $FF then
      bytes[i] := Ord('\')
    else
      bytes[i] := p[i];

  n := MultiByteToWideChar(CP_OEMCP, 0, Pointer(bytes), len, nil, 0);
  SetLength(Result, n);
  if n > 0 then
    MultiByteToWideChar(CP_OEMCP, 0, Pointer(bytes), len, Pointer(Result), n);
end;

function THaArchive.ReadAt(pos: UInt64; var buf; size: UInt32): UInt32;
var
  got: UInt32;
begin
  Result := 0;

  if FAILED(FStream.Seek(Int64(pos), STREAM_SEEK_SET, nil)) then
    Exit;

  while Result < size do
  begin
    got := 0;
    if FAILED(FStream.Read(PByte(@buf) + Result, size - Result, @got)) or (got = 0) then
      Break;
    Inc(Result, got);
  end;
end;

function THaArchive.ParseItem(pos, arcSize: UInt64; out item: THaItem; out deleted: Boolean;
  out nextPos: UInt64): Boolean;
var
  buf: array [0..HaHeaderBufSize - 1] of Byte;
  n, pathEnd, nameEnd, mdiLen, hdrLen: UInt32;
  ver, method: Byte;
  path, name: string;
begin
  Result := False;
  deleted := False;
  nextPos := pos;
  item := Default(THaItem);

  if arcSize - pos > HaHeaderBufSize then
    n := HaHeaderBufSize
  else
    n := arcSize - pos;
  n := ReadAt(pos, buf, n);
  if n < HaFixedHeaderSize + 3 then
    Exit;

  pathEnd := HaFixedHeaderSize;
  while (pathEnd < n) and (buf[pathEnd] <> 0) do
    Inc(pathEnd);
  nameEnd := pathEnd + 1;
  while (nameEnd < n) and (buf[nameEnd] <> 0) do
    Inc(nameEnd);
  if nameEnd + 1 >= n then
    Exit;

  mdiLen := buf[nameEnd + 1];
  hdrLen := nameEnd + 2 + mdiLen;
  if hdrLen > n then
    Exit;

  deleted := buf[0] = HaDeletedMark;
  ver := buf[0] shr 4;
  method := buf[0] and $F;

  if not deleted then
    if (ver <> HaVersion) or not (method in [HaMethodCpy, HaMethodAsc, HaMethodHsc, HaMethodDir, HaMethodSpecial]) then
      Exit;

  item.Method := method;
  item.PackSize := GetUInt32(@buf[1]);
  item.Size := GetUInt32(@buf[5]);
  item.Crc := GetUInt32(@buf[9]);
  UnixTimeToFileTime(GetUInt32(@buf[13]), item.Time);
  item.DataPos := pos + hdrLen;

  path := DecodeHaPath(@buf[HaFixedHeaderSize], pathEnd - HaFixedHeaderSize);
  name := DecodeHaPath(@buf[pathEnd + 1], nameEnd - pathEnd - 1);
  if (path <> '') and (path[Length(path)] <> '\') then
    path := path + '\';
  item.Path := path + name;

  if method = HaMethodDir then
    item.Attrib := FileAttributeDirectory
  else
    item.Attrib := FileAttributeArchive;

  // Machine specific information: the MS-DOS type carries the file attributes
  if (mdiLen >= 2) and (buf[nameEnd + 2] = HaMachineMsDos) then
    item.Attrib := buf[nameEnd + 3];

  nextPos := item.DataPos + item.PackSize;
  Result := True;
end;

function THaArchive.Open(stream: IInStream; const maxCheckStartPosition: PUInt64;
  openArchiveCallback: IArchiveOpenCallback): HRESULT;
var
  head: array [0..3] of Byte;
  arcSize, pos, nextPos: UInt64;
  cnt: Integer;
  item: THaItem;
  deleted, first: Boolean;
begin
  Log('THaArchive.Open');
  Result := S_FALSE;
  Close;

  FStream := stream;

  if FAILED(stream.Seek(0, STREAM_SEEK_END, @arcSize)) then
    Exit;

  if (ReadAt(0, head, 4) < 4) or (head[0] <> Ord('H')) or (head[1] <> Ord('A')) then
    Exit;

  InitCrc32Table;

  cnt := head[2] or (head[3] shl 8);
  pos := 4;
  first := True;

  while cnt > 0 do
  begin
    if pos >= arcSize then
    begin
      FErrorFlags := FErrorFlags or kpvErrorFlagsUnexpectedEnd;
      Break;
    end;

    if not ParseItem(pos, arcSize, item, deleted, nextPos) then
    begin
      // The first header must be sane, otherwise this is not an HA archive
      if first then
      begin
        Close;
        Exit;
      end;
      FErrorFlags := FErrorFlags or kpvErrorFlagsHeadersError;
      Break;
    end;

    first := False;
    pos := nextPos;

    if not deleted then
    begin
      SetLength(FItems, Length(FItems) + 1);
      FItems[High(FItems)] := item;
      Dec(cnt);
    end;

    if pos > arcSize then
    begin
      FErrorFlags := FErrorFlags or kpvErrorFlagsUnexpectedEnd;
      Break;
    end;
  end;

  if pos > arcSize then
    pos := arcSize;
  FPhySize := pos;

  Log(Length(FItems));
  Result := S_OK;
end;

function THaArchive.Close: HRESULT;
begin
  Log('THaArchive.Close');
  FStream := nil;
  FItems := nil;
  FPhySize := 0;
  FErrorFlags := 0;
  Result := S_OK;
end;

function THaArchive.GetNumberOfItems(out numItems: UInt32): HRESULT;
begin
  numItems := Length(FItems);
  Result := S_OK;
end;

function THaArchive.GetProperty(index: UInt32; propID: PROPID; out value: PROPVARIANT): HRESULT;
begin
  value.Init;
  Result := S_OK;

  if index >= UInt32(Length(FItems)) then
  begin
    Result := E_INVALIDARG;
    Exit;
  end;

  case propID of
    kpidPath:
      value.SetString(FItems[index].Path);
    kpidIsDir:
      value.SetBool(FItems[index].Method = HaMethodDir);
    kpidSize:
      value.SetUInt64(FItems[index].Size);
    kpidPackSize:
      value.SetUInt64(FItems[index].PackSize);
    kpidAttrib:
      value.SetUInt32(FItems[index].Attrib);
    kpidCRC:
      if FItems[index].Method <> HaMethodDir then
        value.SetUInt32(FItems[index].Crc);
    kpidMTime:
      value.SetTime(FItems[index].Time);
    kpidMethod:
      case FItems[index].Method of
        HaMethodCpy:
          value.SetString('CPY');
        HaMethodAsc:
          value.SetString('ASC');
        HaMethodHsc:
          value.SetString('HSC');
        HaMethodDir:
          value.SetString('DIR');
        HaMethodSpecial:
          value.SetString('SPECIAL');
      end;
  end;
end;

function THaArchive.UnpackItem(const item: THaItem; outStream: ISequentialOutStream;
  callback: IArchiveExtractCallback; var done: UInt64; out opRes: Integer): HRESULT;
var
  crc: UInt32;
  cur, start: UInt64;
  hr: HRESULT;
  res: THaResult;
  readFn: THaReadFunc;
  writeFn: THaWriteFunc;
begin
  Result := S_OK;
  opRes := NArchive.NExtract.NOperationResult.kOK;

  start := done;
  cur := done;
  crc := $FFFFFFFF;
  hr := S_OK;

  if (item.Size > 0) or (item.PackSize > 0) then
  begin
    if FAILED(FStream.Seek(Int64(item.DataPos), STREAM_SEEK_SET, nil)) then
    begin
      opRes := NArchive.NExtract.NOperationResult.kUnavailable;
      Exit;
    end;

    readFn :=
      function(var buf; size: Integer): Integer
      var
        got: UInt32;
      begin
        got := 0;
        if FAILED(FStream.Read(@buf, size, @got)) then
          Exit(-1);
        Result := got;
      end;
    writeFn :=
      function(const buf; size: Integer): Boolean
      var
        written, wrote: UInt32;
      begin
        Result := False;
        crc := UpdateCrc32(crc, @buf, size);

        if Assigned(outStream) then
        begin
          written := 0;
          while written < UInt32(size) do
          begin
            wrote := 0;
            hr := outStream.Write(PByte(@buf) + written, UInt32(size) - written, @wrote);
            if hr <> S_OK then
              Exit;
            if wrote = 0 then
            begin
              hr := E_FAIL;
              Exit;
            end;
            Inc(written, wrote);
          end;
        end;

        Inc(cur, UInt32(size));
        hr := callback.SetCompleted(@cur);
        Result := hr = S_OK;
      end;

    if item.Method = HaMethodHsc then
      res := HscUnpack(readFn, writeFn, item.PackSize, item.Size)
    else
      res := AscUnpack(readFn, writeFn, item.PackSize, item.Size);

    if hr <> S_OK then
      Exit(hr);

    case res of
      arOk:
        if (crc xor $FFFFFFFF) <> item.Crc then
          opRes := NArchive.NExtract.NOperationResult.kCRCError;
      arUnexpectedEnd:
        opRes := NArchive.NExtract.NOperationResult.kUnexpectedEnd;
      arReadError:
        opRes := NArchive.NExtract.NOperationResult.kUnavailable;
    else
      opRes := NArchive.NExtract.NOperationResult.kDataError;
    end;
  end
  else if (crc xor $FFFFFFFF) <> item.Crc then
    opRes := NArchive.NExtract.NOperationResult.kCRCError;

  done := start + item.Size;
end;

function THaArchive.CopyItem(const item: THaItem; outStream: ISequentialOutStream;
  callback: IArchiveExtractCallback; var done: UInt64; out opRes: Integer): HRESULT;
var
  buf: TArray<Byte>;
  remaining: UInt64;
  chunk, got, written, wrote: UInt32;
  crc: UInt32;
begin
  Result := S_OK;
  opRes := NArchive.NExtract.NOperationResult.kOK;

  if item.Method = HaMethodDir then
    Exit;

  if item.Method in [HaMethodAsc, HaMethodHsc] then
    Exit(UnpackItem(item, outStream, callback, done, opRes));

  // Only the CPY (stored), ASC and HSC methods are supported
  if item.Method <> HaMethodCpy then
  begin
    opRes := NArchive.NExtract.NOperationResult.kUnsupportedMethod;
    Inc(done, item.Size);
    Exit;
  end;

  if item.PackSize <> item.Size then
  begin
    opRes := NArchive.NExtract.NOperationResult.kDataError;
    Inc(done, item.Size);
    Exit;
  end;

  if (item.Size > 0) and FAILED(FStream.Seek(Int64(item.DataPos), STREAM_SEEK_SET, nil)) then
  begin
    opRes := NArchive.NExtract.NOperationResult.kUnavailable;
    Exit;
  end;

  SetLength(buf, HaCopyBufSize);
  crc := $FFFFFFFF;
  remaining := item.Size;

  while remaining > 0 do
  begin
    chunk := HaCopyBufSize;
    if chunk > remaining then
      chunk := remaining;

    got := 0;
    Result := FStream.Read(Pointer(buf), chunk, @got);
    if FAILED(Result) then
      Exit;
    if got = 0 then
    begin
      opRes := NArchive.NExtract.NOperationResult.kUnexpectedEnd;
      Result := S_OK;
      Exit;
    end;

    crc := UpdateCrc32(crc, Pointer(buf), got);

    if Assigned(outStream) then
    begin
      written := 0;
      while written < got do
      begin
        wrote := 0;
        Result := outStream.Write(PByte(buf) + written, got - written, @wrote);
        if Result <> S_OK then
          Exit;
        if wrote = 0 then
        begin
          Result := E_FAIL;
          Exit;
        end;
        Inc(written, wrote);
      end;
    end;

    Dec(remaining, got);
    Inc(done, got);

    Result := callback.SetCompleted(@done);
    if Result <> S_OK then
      Exit;
  end;

  if (crc xor $FFFFFFFF) <> item.Crc then
    opRes := NArchive.NExtract.NOperationResult.kCRCError;
end;

function THaArchive.Extract(const indices: PUInt32; numItems: UInt32; testMode: Integer;
  extractCallback: IArchiveExtractCallback): HRESULT;
var
  all: Boolean;
  i, idx: UInt32;
  total, done: UInt64;
  askMode, opRes: Integer;
  outStream: ISequentialOutStream;
begin
  Log('THaArchive.Extract');

  all := numItems = UInt32(-1);
  if all then
    numItems := Length(FItems);

  total := 0;
  for i := 0 to numItems - 1 do
  begin
    if all then
      idx := i
    else
      idx := PUInt32(PByte(indices) + i * SizeOf(UInt32))^;

    if idx >= UInt32(Length(FItems)) then
    begin
      Result := E_INVALIDARG;
      Exit;
    end;
    Inc(total, FItems[idx].Size);
  end;

  Result := extractCallback.SetTotal(total);
  if Result <> S_OK then
    Exit;

  if testMode <> 0 then
    askMode := NArchive.NExtract.NAskMode.kTest
  else
    askMode := NArchive.NExtract.NAskMode.kExtract;

  done := 0;

  for i := 0 to numItems - 1 do
  begin
    if all then
      idx := i
    else
      idx := PUInt32(PByte(indices) + i * SizeOf(UInt32))^;

    Result := extractCallback.SetCompleted(@done);
    if Result <> S_OK then
      Exit;

    outStream := nil;
    Result := extractCallback.GetStream(idx, outStream, askMode);
    if Result <> S_OK then
      Exit;

    if (FItems[idx].Method <> HaMethodDir) and (testMode = 0) and not Assigned(outStream) then
    begin
      Inc(done, FItems[idx].Size);
      Continue;
    end;

    Result := extractCallback.PrepareOperation(askMode);
    if Result <> S_OK then
      Exit;

    Result := CopyItem(FItems[idx], outStream, extractCallback, done, opRes);
    if Result <> S_OK then
      Exit;

    outStream := nil;

    Result := extractCallback.SetOperationResult(opRes);
    if Result <> S_OK then
      Exit;
  end;

  Result := S_OK;
end;

function THaArchive.GetArchiveProperty(propID: PROPID; out value: PROPVARIANT): HRESULT;
begin
  value.Init;
  Result := S_OK;

  case propID of
    kpidPhySize:
      value.SetUInt64(FPhySize);
    kpidErrorFlags:
      if FErrorFlags <> 0 then
        value.SetUInt32(FErrorFlags);
  end;
end;

function THaArchive.GetNumberOfProperties(out numProperties: UInt32): HRESULT;
begin
  numProperties := Length(PropIds);

  Result := S_OK;
end;

function THaArchive.GetPropertyInfo(index: UInt32; out name: TBStr; out propID: PROPID; out varType: TVarType): HRESULT;
begin
  name := nil;

  if index >= UInt32(Length(PropIds)) then
  begin
    Result := E_INVALIDARG;
    Exit;
  end;

  propID := PropIds[index];
  varType := PropTypes[index];

  Result := S_OK;
end;

function THaArchive.GetNumberOfArchiveProperties(out numProperties: UInt32): HRESULT;
begin
  numProperties := 0;

  Result := S_OK;
end;

function THaArchive.GetArchivePropertyInfo(index: UInt32; out name: TBStr; out propID: PROPID; out varType: TVarType): HRESULT;
begin
  name := nil;

  Result := E_INVALIDARG;
end;
