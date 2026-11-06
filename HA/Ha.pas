//
// HA 7-Zip Format
//
// Copyright (C) 2026, Yegor Mialyk. All Rights Reserved.
//
// Licensed under the GPL License. See the LICENSE file for details.
//

library Ha;

{$INCLUDE Compiler.pas}

{$R *.g.res}

uses
  Winapi.Windows,
  Winapi.ActiveX,
  SevenZip,
  Ha.Asc,
  Ha.Hsc,
  My.Lib;

{$INCLUDE ..\..\Projects\Lib\propvariant.pas}
{$INCLUDE inarchive.pas}

const
  HaGuid: TGuid = '{310914E3-0F2C-4499-BF1B-657AD751C612}';

function GetNumberOfFormats(out numFormats: UInt32): HRESULT; stdcall;
begin
  Log('GetNumberOfFormats');

  numFormats := 1;

  Result := S_OK;
end;

function GetHandlerProperty2(index: UInt32; prop_id: PROPID; out value: PROPVARIANT): HRESULT; stdcall;
begin
  Log('GetHandlerProperty2');
  Log(Format('index=%d, prop_id=%d', [index, prop_id]));

  value.Init;
  case prop_id of
    NArchive.NHandlerPropID.kName:
      value.SetString('HA');
    NArchive.NHandlerPropID.kExtension:
      value.SetString('ha');
    NArchive.NHandlerPropID.kClassID:
      value.SetData(@HaGuid, SizeOf(TGUID));
    NArchive.NHandlerPropID.kSignature:
      value.SetData(@HaSignature, SizeOf(HaSignature));
    NArchive.NHandlerPropID.kUpdate:
      value.SetBool(False);
  else
    Log('not found');
  end;

  Result := S_OK;
end;

function CreateObject(class_id: PGUID; interface_id: PGUID; out Obj: IUnknown): HRESULT; stdcall;
begin
  Log('CreateObject');

  if not IsEqualGUID(class_id^, HaGuid) then
  begin
    Result := CLASS_E_CLASSNOTAVAILABLE;
    Exit;
  end;

  if not IsEqualGUID(interface_id^, IInArchive) then
  begin
    Log('!IID_IInArchive');
    Result := E_NOINTERFACE;
    Exit;
  end;

  Obj := THaArchive.Create as IInArchive;
  Result := S_OK;
end;

function IsHaArchive(const data: PByte; size: UIntPtr): UInt32; stdcall;
var
  i: Integer;
begin
  for i := 0 to High(HaSignature) do
  begin
    if size <= UIntPtr(i) then
      Exit(k_IsArc_Res_NEED_MORE);
    if data[i] <> HaSignature[i] then
      Exit(k_IsArc_Res_NO);
  end;
  Result := k_IsArc_Res_YES;
end;

function GetIsArc(formatIndex: UInt32; out isArc: Pointer): HRESULT; stdcall;
begin
  isArc := nil;

  if formatIndex <> 0 then
    Exit(E_INVALIDARG);

  isArc := @IsHaArchive;

  Result := S_OK;
end;

exports
  GetNumberOfFormats,
  GetHandlerProperty2,
  CreateObject,
  GetIsArc;

{$IFDEF _ADD_LIBLOG_}
begin
  InitLog('HaLog');
{$ENDIF}
end.
