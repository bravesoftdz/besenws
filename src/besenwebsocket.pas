unit besenwebsocket;
{
 asynchronous besen classes for websockets (and regular http requests)

 Copyright (C) 2016 Simon Ley

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published
 by the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU Lesser General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>.
}
{$i besenws.inc}

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  contnrs,
  {$i besenunits.inc},
  beseninstance,
  besenevents,
  epollsockets,
  webserverhosts,
  webserver;

type
  //TOpenSSLBesenWorkAroundThread = class(TThread)
  { TBESENWebsocketClient }

  { client object - this is created automatically for each new connection and
    passed to the script via global handler object callbacks.

    for regular http clients, .disconnect() must be called after the request
    has been processed. Otherwise the client will never receive a response
  }
  TBESENWebsocketClient = class(TBESENNativeObject)
  private
    FIsRequest: Boolean;
    FMimeType: TBESENString;
    FReply: TBESENString;
    FConnection: THTTPConnection;
    FReturnType: TBESENString;
    FRefCounter: Integer;
    function GetHostname: string;
    function GetLag: Integer;
    function GetParameter: TBESENString;
    function GetPingTime: Integer;
    function GetPongTime: Integer;
    function GetPostData: string;
    procedure SetPingTime(AValue: Integer);
    procedure SetPongTime(AValue: Integer);
  protected
    procedure InitializeObject; override;
    procedure FinalizeObject; override;
  public
    procedure AddRefCount;
    procedure DecRefCount;
  published
    { send(data) - sends data to client }
    procedure send(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { disconnect() - disconnects the client }
    procedure disconnect(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { getHeader(item) - returns an entry from the http request header }
    procedure getHeader(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { redirect(url) - perform a redirect (if not websocket) }
    procedure redirect(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { the remote client ip }
    property host: string read GetHostname;
    { client lag - only measured/updated during idle pings }
    property lag: Integer read GetLag;
    { raw http post data (for regular http requests) }
    property postData: string read GetPostData;
    { ping interval for client connection (only sent when idle), in seconds }
    property pingTime: Integer read GetPingTime write SetPingTime;
    { maximum timeframe for a ping-reply before the connection is dropped }
    property maxPongTime: Integer read GetPongTime write SetPongTime;
    { the mime type for the response. usually "text/html" }
    property mimeType: TBESENString read FMimeType write FMimeType;
    { the http response message. usually "200 OK" }
    property returnType: TBESENString read FReturnType write FReturnType;
    { the http request uri parameter }
    property parameter: TBESENString read GetParameter;
  end;

  TBESENWebsocket = class;
  { TBESENWebsocketHandler }

  { global handler object for websocket scripts }
  TBESENWebsocketHandler = class(TBESENNativeObject)
  private
    FOnConnect: TBESENObjectFunction;
    FOnData: TBESENObjectFunction;
    FOnDisconnect: TBESENObjectFunction;
    FOnRequest: TBESENObjectFunction;
    FUrl: TBESENString;
    FParentThread: TBESENWebsocket;
    function GetUnloadTimeout: Integer;
    procedure SetUnloadTimeout(AValue: Integer);
  published
    { onRequest = function(client) - callback function for an incoming regular http request }
    property onRequest: TBESENObjectFunction read FOnRequest write FOnRequest;
    { onConnect = function(client) - callback function for new incoming websocket connection }
    property onConnect: TBESENObjectFunction read FOnConnect write FOnConnect;
    { onData = function(client, data) - callback function for incoming websocket client data }
    property onData: TBESENObjectFunction read FOnData write FOnData;
    { onDisconnect = function(client) - callback function when a client disconnects }
    property onDisconnect: TBESENObjectFunction read FOnDisconnect write FOnDisconnect;
    property url: TBESENString read FUrl;
    property unloadTimeout: Integer read GetUnloadTimeout write SetUnloadTimeout;
  end;

  { TBESENWebsocketBulkSender }
  { bulk message sending object - sends the same message to multiple websocket clients,
    performs slightly better than implementing the same thing in ECMAScript }
  TBESENWebsocketBulkSender = class(TBESENNativeObject)
  private
    FClients: array of TBESENWebsocketClient;
    function GetLength: Integer;
  protected
    procedure InitializeObject; override;
    procedure FinalizeObject; override;
    function RemoveClient(Client: TBESENWebsocketClient): Boolean;
  published
    { add(client) - add a websocket client into bulk send list }
    procedure add(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { remove(client) - remove client from bulk send list }
    procedure remove(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { send(data - send data to all clients in bulk send list}
    procedure send(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { amount of clients in list }
    property count: Integer read GetLength;
  end;

  { TBESENWebsocket }

  TBESENWebsocket = class(TEPollWorkerThread)
  private
    FAutoUnload: Integer;
    FFilename: string;
    FSite: TWebserverSite;
    FInstance: TBESENInstance;
    FHandler: TBESENWebsocketHandler;
    FClients: array of TBESENWebsocketClient;
    FIdleTicks,FGCTicks: Integer;
    FUrl: TBESENString;
    FFlushList: TObjectList;
  protected
    procedure LoadBESEN;
    procedure UnloadBESEN;
    function GetClient(AClient: THTTPConnection): TBESENWebsocketClient;
    procedure ThreadTick; override;
    procedure AddConnection(Client: TEPollSocket);
    procedure ClientData(Sender: THTTPConnection; const data: ansistring);
    procedure ClientDisconnect(Sender: TEPollSocket);
    procedure Initialize; override;
  public
    constructor Create(aParent: TWebserver; ASite: TWebserverSite; AFile: string; Url: TBESENString);
    destructor Destroy; override;
    procedure AddConnectionToFlush(AConnection: THTTPConnection);
    property Site: TWebserverSite read FSite;
    property AutoUnload: Integer read FAutoUnload write FAutoUnload;
  end;

implementation

uses
  besenserverconfig,
  logging;

{ TBESENWebsocketBulkSender }

function TBESENWebsocketBulkSender.GetLength: Integer;
begin
  result:=Length(FClients);
end;

procedure TBESENWebsocketBulkSender.InitializeObject;
begin
  inherited InitializeObject;
end;

procedure TBESENWebsocketBulkSender.FinalizeObject;
var
  i: Integer;
begin
  for i:=0 to Length(FClients)-1 do
    FClients[i].DecRefCount;
  Setlength(FClients, 0);
  inherited FinalizeObject;
end;

function TBESENWebsocketBulkSender.RemoveClient(Client: TBESENWebsocketClient
  ): Boolean;
var
  i: Integer;
begin
  result:=False;
  for i:=0 to Length(FClients)-1 do
  begin
    if FClients[i] = Client then
    begin
      FClients[i]:=FClients[Length(FClients)-1];
      Setlength(FClients, Length(FClients)-1);
      result:=True;
      Exit;
    end;
  end;
end;

procedure TBESENWebsocketBulkSender.add(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  o: TBESENObject;
  i: Integer;
begin
  ResultValue:=BESENBooleanValue(False);
  if CountArguments<1 then
    Exit;
  o:=TBESEN(Instance).ToObj(Arguments^[0]^);
  if Assigned(o) and (o is TBESENWebsocketClient) then
  begin
    if not TBESENWebsocketClient(o).FIsRequest then
    begin
      i:=Length(FClients);
      Setlength(FClients, i+1);
      FClients[i]:=TBESENWebsocketClient(o);
      ResultValue:=BESENBooleanValue(True);
    end;
  end else
    raise EBESENError.Create('Websocket client object expected');
end;

procedure TBESENWebsocketBulkSender.remove(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  o: TBESENObject;
begin
  ResultValue:=BESENBooleanValue(False);
  if CountArguments<1 then
    Exit;
  o:=TBESEN(Instance).ToObj(Arguments^[0]^);
  if Assigned(o) and (o is TBESENWebsocketClient) then
  begin
    ResultValue:=BESENBooleanValue(RemoveClient(TBESENWebsocketClient(o)));
  end else
    raise EBESENError.Create('Websocket client object expected');
end;

procedure TBESENWebsocketBulkSender.send(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  i: Integer;
  data: ansistring;
begin
  resultValue:=BESENBooleanValue(False);
  if CountArguments<1 then
    Exit;

  data:=BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^));

  for i:=0 to Length(FClients)-1 do
  with FClients[i] do
  if (Assigned(FConnection)) then
  begin
    if FConnection.Closed then
    begin
      RemoveClient(FClients[i]);
    end else
    begin
      FConnection.SendWS(Data, not FConnection.IsSSL);
      if FConnection.IsSSL then
       TBESENWebsocket(FConnection.Parent).AddConnectionToFlush(FConnection);
    end;
  end else
    RemoveClient(FClients[i]);
end;

{ TBESENWebsocketHandler }

function TBESENWebsocketHandler.GetUnloadTimeout: Integer;
begin
  result:=FParentThread.AutoUnload;
end;

procedure TBESENWebsocketHandler.SetUnloadTimeout(AValue: Integer);
begin
  FParentThread.AutoUnload:=AValue;
end;

{ TBESENWebsocketHandler }

constructor TBESENWebsocket.Create(aParent: TWebserver; ASite: TWebserverSite;
  AFile: string; Url: TBESENString);
begin
  FSite:=ASite;
  OnConnection:=AddConnection;
  FFilename:=ASite.Path+'scripts/'+AFile;
  FInstance:=nil;
  FURL:=Url;
  FAutoUnload:=20000;
  FFlushList:=TObjectList.Create(False);
  inherited Create(aParent);
end;

destructor TBESENWebsocket.Destroy; 
begin
  inherited; 
  UnloadBESEN;
  FFlushList.Free;
end;

procedure TBESENWebsocket.AddConnectionToFlush(AConnection: THTTPConnection);
begin
  if FFlushList.IndexOf(AConnection) = -1 then
    FFLushList.Add(AConnection);
end;

procedure TBESENWebsocket.LoadBESEN;
begin
  dolog(llDebug, 'Loading BESEN Websocket '+StripBasePath(FFilename));
  if Assigned(FInstance) then
    Exit;

  FInstance:=TBESENInstance.Create(FSite.Parent, FSite, self);
  FHandler:=TBESENWebsocketHandler.Create(FInstance);
  FHandler.InitializeObject;
  FHandler.FUrl:=FUrl;
  FHandler.FParentThread:=Self;

  FInstance.GarbageCollector.Add(TBESENObject(FHandler));
  FInstance.GarbageCollector.Protect(TBESENObject(FHandler));

  FInstance.ObjectGlobal.put('handler', BESENObjectValue(FHandler), false);
  FInstance.RegisterNativeObject('BulkSender', TBESENWebsocketBulkSender);
  FInstance.SetFilename(FFilename);
  try
    FInstance.Execute(BESENGetFileContent(FFilename));
  except
    on e: Exception do
      FInstance.OutputException(e, 'websocket-init');
  end;
end;

procedure TBESENWebsocket.UnloadBESEN;
var
  conn: THTTPConnection;
begin
  if FInstance = nil then
    Exit;

  dolog(llDebug, 'Unloading BESEN Websocket '+StripBasePath(FFilename));

  while Length(FClients)>0 do
  begin
    conn:=FClients[0].FConnection;
    if Assigned(conn) then
    begin
      ClientDisconnect(conn);
      TWebserver(Parent).FreeConnection(conn);
    end;
  end;

  FInstance.GarbageCollector.UnProtect(TBESENObject(FHandler));

  FInstance.Free;
  FInstance:=nil;
  FHandler:=nil;
end;

procedure TBESENWebsocket.ClientData(Sender: THTTPConnection; const data: ansistring);
var
  client: TBESENWebsocketClient;
  a: array[0..1] of PBESENValue;
  v,v2, AResult: TBESENValue;
begin
  client:=GetClient(Sender);

  if not Assigned(client) then
  begin
    dolog(llDebug, 'Got websocket client-data with no associated client');
    Sender.Close;
    Exit;
  end;

  a[0]:=@v;
  a[1]:=@v2;

  v:=BESENObjectValue(client);

  v2:=BESENStringValue(BESENUTF8ToUTF16(data));
  try
    if Assigned(FHandler.onData) then
      FHandler.onData.Call(BESENObjectValue(FHandler), @a, 2, AResult)
    else
     dolog(llDebug, 'No Data handler');
  except
    on e: Exception do
      FInstance.OutputException(e, 'handler.onData');
  end;
end;

procedure TBESENWebsocket.ClientDisconnect(Sender: TEPollSocket);
var
  client: TBESENWebsocketClient;
  a: array[0..0] of PBESENValue;
  v, AResult: TBESENValue;
  i: Integer;
begin
  if not (Sender is THTTPConnection) then
    Exit;

  client:=GetClient(THTTPConnection(Sender));

  if not Assigned(client) then
    Exit;

  a[0]:=@v;
  v:=BESENObjectValue(client);

  if not client.FIsRequest then
  begin
    if Assigned(FHandler.onDisconnect) then
    try
      FHandler.onDisconnect.Call(BESENObjectValue(FHandler), @a, 1, AResult);
    except
      on e: Exception do
        FInstance.OutputException(e, 'handler.onDisconnect');
    end;
  end;
  client.DecRefCount;

  i:=FFlushList.IndexOf(Sender);
  if i>=0 then
    FFlushList.Delete(i);

  for i:=0 to Length(FClients)-1 do
    if FClients[i] = client then
    begin
      FClients[i]:=FClients[Length(FClients)-1];
      Setlength(FClients, Length(FClients)-1);
      Break;
    end;

  client.FConnection:=nil;
end;

procedure TBESENWebsocket.Initialize;
begin
  inherited Initialize;
  LoadBESEN;
end;

function TBESENWebsocket.GetClient(AClient: THTTPConnection): TBESENWebsocketClient;
var
  i: Integer;
begin
  result:=nil;
  if not Assigned(AClient) then
    Exit;

  for i:=0 to Length(FClients)-1 do
    if FClients[i].FConnection = AClient then
    begin
      result:=FClients[i];
      Exit;
    end;
end;

procedure TBESENWebsocket.AddConnection(Client: TEPollSocket);
var
  i: Integer;
  a: PBESENValue;
  v: TBESENValue;
  AResult: TBESENValue;
  aclient: TBESENWebsocketClient;
begin
  if not Assigned(Client) then
    Exit;

  if not (Client is THTTPConnection) then
    Exit;

  if not Assigned(FInstance) then
    LoadBESEN;

  aclient:=TBESENWebsocketClient.Create(FInstance);
  FInstance.GarbageCollector.Add(TBESENObject(aclient));

  aclient.InitializeObject;
  aclient.AddRefCount;
  aclient.FConnection:=THTTPConnection(Client);
  aclient.FConnection.OnWebsocketData:=ClientData;
  aclient.FConnection.OnDisconnect:=ClientDisconnect;

  a:=@v;
  i:=Length(FClients);
  Setlength(FClients, i+1);
  FClients[i]:=aClient;
  v:=BESENObjectValue(aClient);

  aclient.FIsRequest:=not aclient.FConnection.CanWebsocket;
  if aclient.FIsRequest then
  begin
    try
      if Assigned(FHandler.onRequest) then
        FHandler.onRequest.Call(BESENObjectValue(FHandler), @a, 1, AResult);
    except
      on e: Exception do
        FInstance.OutputException(e, 'handler.onRequest');
    end;
  end else
  begin
    aclient.FConnection.UpgradeToWebsocket;
    try
      if Assigned(FHandler.onConnect) then
        FHandler.onConnect.Call(BESENObjectValue(FHandler), @a, 1, AResult);
    except
      on e: Exception do
        FInstance.OutputException(e, 'handler.onConnect');
    end;
  end;
end;

procedure TBESENWebsocket.ThreadTick;
var
  i: Integer;
begin
  if Assigned(FInstance) then
  begin
    if FFlushList.Count>0 then
    begin
      for i:=0 to FFLushlist.Count-1 do
        THTTPConnection(FFLushList[i]).FlushSendbuffer;
      FFlushList.Clear;
    end;

    FInstance.ProcessHandlers;
    if longword(TWebserver(Parent).Ticks - FGCTicks)>=1000 then
    begin
      FInstance.GarbageCollector.Collect;
      FGCTicks:=TWebserver(Parent).Ticks;
    end;

    if (Length(FClients)>0) then
      FIdleTicks:=0
    else begin
      if FAutoUnload>0 then
      if FIdleTicks * EpollWaitTime > FAutoUnload then
        UnloadBESEN
      else
        inc(FIdleTicks);
    end;
  end;
  inherited;
end;

{ TBESENWebsocketClient }

procedure TBESENWebsocketClient.InitializeObject;
begin
  FReply:='';
  FIsRequest:=False;
  FMimeType:='text/html';
  FReturnType:='200 OK';
  FRefCounter:=0;
  inherited; 
end;

procedure TBESENWebsocketClient.FinalizeObject;
begin
  inherited;
end;

procedure TBESENWebsocketClient.AddRefCount;
begin
  if FRefCounter = 0 then
  begin
    TBESEN(Instance).GarbageCollector.Protect(Self);
  end;
  Inc(FRefCounter);
end;

procedure TBESENWebsocketClient.DecRefCount;
begin
  Dec(FRefCounter);
  if FRefCounter = 0 then
  begin
    TBESEN(Instance).GarbageCollector.Unprotect(Self);
  end else
  if FRefCounter < 0 then
    dolog(llWarning, 'Internal Error: Reference Counter in TBESENWebsocketClient is broken');
end;

procedure TBESENWebsocketClient.send(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  if CountArguments<=0 then
    Exit;

  if not Assigned(FConnection) then
    Exit;

  if FIsRequest then
  begin
    // for a normal http request, we cache the reply and send it out at once
    FReply:=FReply + TBESEN(Instance).ToStr(Arguments^[0]^)
  end else
  begin
    { BUG: Calling OpenSSL functions from a native script callback function
      can cause weird exceptions (from within OpenSSL). Nobody really knows why.
      Therefore, when SSL is used, data is held back and sent after script execution
      has completed
      }
    FConnection.SendWS(BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^)), not FConnection.IsSSL);
    if FConnection.IsSSL then
     TBESENWebsocket(FConnection.Parent).AddConnectionToFlush(FConnection);
  end;
end;

procedure TBESENWebsocketClient.getHeader(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  if CountArguments>0 then
    if(Assigned(FConnection)) then
      ResultValue:=BESENStringValue(BESENUTF8ToUTF16(FConnection.Header.header[BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^))]));
end;

procedure TBESENWebsocketClient.redirect(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  url: ansistring;
begin
  if Assigned(FConnection) then
  begin
    if (CountArguments>0) and FIsRequest then
    begin
      url:=BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^));
      FConnection.Reply.header.Add('Location', url);
      FConnection.SendContent('text/html', '<html><body>Content has been moved to <a href="'+url+'">'+url+'</a></body></html>', '302 Found');
      FConnection.Close;
    end;
  end;
end;


procedure TBESENWebsocketClient.disconnect(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  if Assigned(FConnection) then
  begin
    if FIsRequest then
    begin
      FConnection.SendContent(ansistring(FMimeType), BESENUTF16ToUTF8(FReply), ansistring(FReturnType), not FConnection.IsSSL);
      if FConnection.IsSSL then
       TBESENWebsocket(FConnection.Parent).AddConnectionToFlush(FConnection);
    end;
    FConnection.Close;
  end;
end;

function TBESENWebsocketClient.GetLag: Integer;
begin
  if Assigned(FConnection) then
    result:=FConnection.Lag
  else
    result:=-1;
end;

function TBESENWebsocketClient.GetParameter: TBESENString;
begin
  result:=TBESENString(FConnection.Header.parameters);
end;

function TBESENWebsocketClient.GetPingTime: Integer;
begin
  if Assigned(FConnection) then
    result:=FConnection.WebsocketPingIdleTime
  else
    result:=-1;
end;

function TBESENWebsocketClient.GetPongTime: Integer;
begin
  if Assigned(FConnection) then
    result:=FConnection.WebsocketMaxPongTime
  else
    result:=-1;
end;

function TBESENWebsocketClient.GetPostData: string;
begin
  result:='';
end;

procedure TBESENWebsocketClient.SetPingTime(AValue: Integer);
begin
  if not Assigned(FConnection) then
    Exit;

  if AValue>1 then
    FConnection.WebsocketPingIdleTime:=AValue
  else
    FConnection.WebsocketPingIdleTime:=1
end;

procedure TBESENWebsocketClient.SetPongTime(AValue: Integer);
begin
  if not Assigned(FConnection) then
    Exit;

  if AValue>1 then
    FConnection.WebsocketMaxPongTime:=AValue
  else
    FConnection.WebsocketMaxPongTime:=1
end;

function TBESENWebsocketClient.GetHostname: string;
begin
  if Assigned(FConnection) then
    result:=FConnection.GetRemoteIP
  else
    result:='';
end;

end.

