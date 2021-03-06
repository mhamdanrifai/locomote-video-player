package com.axis.rtspclient {
  import com.axis.ClientEvent;
  import com.axis.NetStreamClient;
  import com.axis.ErrorManager;
  import com.axis.http.auth;
  import com.axis.http.request;
  import com.axis.http.url;
  import com.axis.IClient;
  import com.axis.Logger;
  import com.axis.rtspclient.FLVMux;
  import com.axis.rtspclient.FLVTag;
  import com.axis.rtspclient.FLVSync;
  import com.axis.rtspclient.RTP;
  import com.axis.rtspclient.RTPTiming;
  import com.axis.rtspclient.SDP;

  import flash.events.AsyncErrorEvent;
  import flash.events.Event;
  import flash.events.EventDispatcher;
  import flash.events.IOErrorEvent;
  import flash.events.NetStatusEvent;
  import flash.events.SecurityErrorEvent;
  import flash.media.Video;
  import flash.net.NetConnection;
  import flash.net.NetStream;
  import flash.net.Socket;
  import flash.utils.ByteArray;
  import flash.events.TimerEvent;
  import flash.utils.Timer;

  import mx.utils.StringUtil;

  public class RTSPClient extends NetStreamClient implements IClient {
    [Embed(source = "../../../../VERSION", mimeType = "application/octet-stream")] private var Version:Class;
    private var userAgent:String;

    private static const STATE_INITIAL:uint  = 1 << 0;
    private static const STATE_OPTIONS:uint  = 1 << 1;
    private static const STATE_DESCRIBE:uint = 1 << 2;
    private static const STATE_SETUP:uint    = 1 << 3;
    private static const STATE_PLAY:uint     = 1 << 4;
    private static const STATE_PLAYING:uint  = 1 << 5;
    private static const STATE_PAUSE:uint    = 1 << 6;
    private static const STATE_PAUSED:uint   = 1 << 7;
    private static const STATE_TEARDOWN:uint = 1 << 8;
    private var state:int = STATE_INITIAL;
    private var handle:IRTSPHandle;

    private var sdp:SDP = new SDP();
    private var rtpTiming:RTPTiming;
    private var evoStream:Boolean = false;
    private var flvmux:FLVMux;
    private var flvSync:FLVSync;
    private var streamBuffer:Array = new Array();
    private var frameByFrame:Boolean = false;

    private var urlParsed:Object;
    private var cSeq:uint = 1;
    private var session:String;
    private var contentBase:String;
    private var interleaveChannelIndex:uint = 0;

    private var methods:Array = [];
    private var data:ByteArray = new ByteArray();
    private var rtpLength:int = -1;
    private var rtpChannel:int = -1;
    private var tracks:Array;
    private var startOptions:Object;

    private var prevMethod:Function;

    private var authState:String = "none";
    private var authOpts:Object = {};
    private var digestNC:uint = 1;

    private var bcTimer:Timer;
    private var kaTimer:Timer;
    private var connectionBroken:Boolean = false;

    private var nc:NetConnection = null;

    public function RTSPClient(urlParsed:Object, handle:IRTSPHandle) {
      this.userAgent = "Locomote " + StringUtil.trim(new Version().toString());
      this.state = STATE_INITIAL;
      this.handle = handle;
      this.urlParsed = urlParsed;

      handle.addEventListener('data', this.onData);
    }

    public function start(options:Object):Boolean {
      this.bcTimer = new Timer(Player.config.connectionTimeout * 1000, 1);
      this.bcTimer.stop(); // Don't start timeout immediately
      this.bcTimer.reset();
      this.bcTimer.addEventListener(TimerEvent.TIMER_COMPLETE, bcTimerHandler);

      this.setKeepAlive(Player.config.keepAlive);

      this.startOptions = options;
      if (!this.startOptions.offset) {
        this.startOptions.offset = 0;
      }
      this.frameByFrame = Player.config.frameByFrame;

      var self:RTSPClient = this;
      handle.addEventListener('connected', function():void {
        if (state !== STATE_INITIAL) {
          ErrorManager.dispatchError(805);
          return;
        }
        self.bcTimer.start();

        /* If the handle closes, take care of it */
        handle.addEventListener('closed', self.onClose);

        if (0 === self.methods.length) {
          /* We don't know the options yet. Start with that. */
          sendOptionsReq();
        } else {
          /* Already queried the options (and perhaps got unauthorized on describe) */
          sendDescribeReq();
        }
      });

      nc = new NetConnection();
      nc.connect(null);
      nc.addEventListener(AsyncErrorEvent.ASYNC_ERROR, onAsyncError);
      nc.addEventListener(IOErrorEvent.IO_ERROR, onIOError);
      nc.addEventListener(NetStatusEvent.NET_STATUS, onNetStatusError);
      nc.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onSecurityError);
      this.ns = new NetStream(nc);
      this.setupNetStream();

      handle.connect();
      return true;
    }

    public function pause():Boolean {
      if (state !== STATE_PLAYING) {
        return false;
      }

      state = STATE_PAUSE;

      /* Stop timer, don't close the connection when paused. */
      bcTimer.stop();
      kaTimer.stop();

      this.ns.pause();

      if (!this.evoStream || this.rtpTiming.live) {
        sendPauseReq();
      } else {
        state = STATE_PAUSED;
      }
      return true;
    }

    public function resume():Boolean {
      if (state !== STATE_PAUSED) {
        ErrorManager.dispatchError(801);
        return false;
      }

      /* Start time here so we can get a connection broken if the socket has gone away */
      bcTimer.reset();
      bcTimer.start();

      /* If in live mode, close NetSteam to discard buffer and restart display timing */
      if (this.rtpTiming.live) {
        this.ns.close();
        this.ns.play(null);
      } else {
        this.ns.resume();
      }

      state = STATE_PLAY;
      if (!this.evoStream || this.rtpTiming.live) {
        sendPlayReq();
      } else {
        state = STATE_PLAYING;
      }
      return true;
    }

    public function stop():Boolean {
      dispatchEvent(new ClientEvent(ClientEvent.STOPPED));
      this.ns.dispose();
      bcTimer.stop();

      try {
        sendTeardownReq();
      } catch (e:*) {}

      this.handle.disconnect();

      nc.removeEventListener(AsyncErrorEvent.ASYNC_ERROR, onAsyncError);
      nc.removeEventListener(IOErrorEvent.IO_ERROR, onIOError);
      nc.removeEventListener(NetStatusEvent.NET_STATUS, onNetStatusError);
      nc.removeEventListener(SecurityErrorEvent.SECURITY_ERROR, onSecurityError);

      return true;
    }

    public function seek(position:Number):Boolean {
      return false;
    }

    override public function getCurrentTime():Number {
      var time:Number = super.getCurrentTime();
      if (time != -1 && this.startOptions.offset) {
        time += this.startOptions.offset;
      }
      return time;
    }

    override public function hasStreamEnded():Boolean {
      if (this.streamEnded) {
        return true;
      }

      if (this.streamBuffer.length === 0 && connectionBroken) {
        return true;
      }

      if (!this.rtpTiming || !this.flvmux || this.rtpTiming.live ||
        this.rtpTiming.range.to == -1 || this.streamBuffer.length > 0) {
        return false;
      }

      var streamLastFrame:Number = this.rtpTiming.range.to - Math.ceil(2000 / (this.ns.currentFPS > 1 ? this.ns.currentFPS : 1));
      var streamCurrentBuffer:Number = this.flvmux.getLastTimestamp() + this.startOptions.offset;
      return streamLastFrame <= streamCurrentBuffer;
    }

    public function setFrameByFrame(frameByFrame:Boolean):Boolean {
      this.frameByFrame = frameByFrame;
      return true;
    }

    public function playFrames(timestamp:Number):void {
      while (this.streamBuffer.length > 0 && this.streamBuffer[0].timestamp <= timestamp) {
        var tag:FLVTag = this.streamBuffer.shift();
        this.ns.appendBytes(tag.data);
        tag.data.clear();
      }
      streamEnded = this.hasStreamEnded();
    }

    private function onFlvTag(tag:FLVTag):void {
      if (this.frameByFrame) {
        this.streamBuffer.push(tag.copy());
        dispatchEvent(new ClientEvent(ClientEvent.FRAME, tag.timestamp));
      } else {
        this.ns.appendBytes(tag.data);
        streamEnded = this.hasStreamEnded();
      }
    }

    public function setBuffer(seconds:Number):Boolean {
      this.ns.bufferTime = seconds;
      this.ns.pause();
      this.ns.resume();
      return true;
    }

    public function setKeepAlive(seconds:Number):Boolean {
      if (seconds !== 0) {
        this.kaTimer = new Timer(seconds * 1000);
      } else if (this.kaTimer) {
        this.kaTimer.stop();
      }
      return true;
    }

    private function onClose(event:Event):void {
      Logger.log("RTSP stream closed", { state: state, streamBuffer: this.streamBuffer.length });
      streamEnded = true;
      this.connectionBroken = true;

      bcTimer.stop();
      this.bcTimer.removeEventListener(TimerEvent.TIMER_COMPLETE, bcTimerHandler);

      if (state !== STATE_TEARDOWN) {
        if (this.streamBuffer.length > 0 && this.streamBuffer[this.streamBuffer.length - 1].timestamp - this.ns.time * 1000 < this.ns.bufferTime * 1000) {
          this.ns.bufferTime = 0;
          this.ns.pause();
          this.ns.resume();
        } else if (bufferEmpty && this.streamBuffer.length === 0) {
          dispatchEvent(new ClientEvent(ClientEvent.STOPPED, { currentTime: this.getCurrentTime() }));
          this.ns.dispose();
        }
      }
    }

    private function onData(event:Event):void {
      if (state === STATE_PLAYING) {
        bcTimer.reset();
        bcTimer.start();
        connectionBroken = false;
      }

      if (0 < data.bytesAvailable) {
        /* Determining byte have already been read. This is a continuation */
      } else {
        /* Read the determining byte */
        handle.readBytes(data, data.position, 1);
      }

      switch(data[0]) {
        case 0x52:
          /* ascii 'R', start of RTSP */
          onRTSPCommand();
          break;

        case 0x24:
          /* ascii '$', start of interleaved packet */
          onInterleavedData();
          break;

        default:
          ErrorManager.dispatchError(804, [data[0].toString(16)]);
          stop();
          break;
      }
    }

    private function requestReset():void {
      var copy:ByteArray = new ByteArray();
      data.readBytes(copy);
      data.clear();
      copy.readBytes(data);

      rtpLength  = -1;
      rtpChannel = -1;
    }

    private function readRequest(oBody:ByteArray):* {
      var parsed:* = request.readHeaders(handle, data);
      if (false === parsed) {
        return false;
      }

      if (401 === parsed.code) {
        /* Unauthorized, change authState and (possibly) try again */
        authOpts = parsed.headers['www-authenticate'];

        if (authOpts.stale && authOpts.stale.toUpperCase() === 'TRUE') {
          requestReset();
          prevMethod();
          return false;
        }

        var newAuthState:String = auth.nextMethod(authState, authOpts);
        if (authState === newAuthState) {
          ErrorManager.dispatchError(parsed.code);
          return false;
        }

        Logger.log('RTSPClient: switching authorization from ' + authState + ' to ' + newAuthState);
        authState = newAuthState;
        state = STATE_INITIAL;
        data = new ByteArray();
        handle.reconnect();
        return false;
      }

      if (isNaN(parsed.code)) {
        ErrorManager.dispatchError(parsed.code);
        return false;
      }

      if (parsed.headers['content-length']) {
        if (data.bytesAvailable < parsed.headers['content-length']) {
          return false;
        }

        /* RTSP commands contain no heavy body, so it's safe to read everything */
        data.readBytes(oBody, 0, parsed.headers['content-length']);
        Logger.log('RTSP IN:', oBody.toString());
      } else {
        Logger.log('RTSP IN:', data.toString());
      }

      requestReset();
      return parsed;
    }

    private function onRTSPCommand():void {
      var parsed:*, body:ByteArray = new ByteArray();
      if (false === (parsed = readRequest(body))) {
        return;
      }

      if (200 !== parsed.code) {
        ErrorManager.dispatchError(parsed.code);
        return;
      }

      switch (state) {
      case STATE_INITIAL:
        Logger.log("RTSPClient: STATE_INITIAL");

      case STATE_OPTIONS:
        Logger.log("RTSPClient: STATE_OPTIONS");
        this.methods = parsed.headers.public.split(/[ ]*,[ ]*/);
        if (parsed.headers['server'] === 'EvoStream Media Server (www.evostream.com)') {
          this.evoStream = true;
        }
        sendDescribeReq();

        break;
      case STATE_DESCRIBE:
        Logger.log("RTSPClient: STATE_DESCRIBE");

        if (!sdp.parse(body)) {
          ErrorManager.dispatchError(806);
          return;
        }

        contentBase = parsed.headers['content-base'];
        tracks = sdp.getMediaBlockList();
        Logger.log('SDP contained ' + tracks.length + ' track(s). Calling SETUP for each.');

        if (0 === tracks.length) {
          ErrorManager.dispatchError(807);
          return;
        }

        /* Fall through, it's time for setup */
      case STATE_SETUP:
        Logger.log("RTSPClient: STATE_SETUP");
        Logger.log(parsed.headers['transport']);

        if (parsed.headers['session']) {
          session = parsed.headers['session'].match(/^[^;]+/)[0];
        }

        if (state === STATE_SETUP) {
          /* this is not the case when falling through, e.g. SETUP of first track */
          if (!(/^RTP\/AVP\/TCP;/.test(parsed.headers["transport"]) &&
            /unicast/.test(parsed.headers["transport"]) &&
            /interleaved=/.test(parsed.headers["transport"]) )){
            dispatchEvent(new ClientEvent(ClientEvent.STOPPED));
            connectionBroken = true;
            handle.disconnect();
            this.ns.dispose();
            ErrorManager.dispatchError(461);
            return;
          }
        }

        if (0 !== tracks.length) {
          /* More tracks we must setup before playing */
          var block:Object = tracks.shift();
          sendSetupReq(block);
          return;
        }

        /* All tracks setup and ready to go! */

        /* Put the NetStream in 'Data Generation Mode'. Data is generated by FLVMux */
        this.ns.play(null);

        state = STATE_PLAY;
        if (this.startOptions.offset > 0) {
          sendPlayReq(startOptions.offset);
        } else {
          sendPlayReq();
        }
        break;
      case STATE_PLAY:
        Logger.log("RTSPClient: STATE_PLAY");
        state = STATE_PLAYING;
        /* Get range from RTSP header or SDP session block */
        var RTPrange = parsed.headers['range'] || this.sdp.getSessionBlock().range;
        rtpTiming = RTPTiming.parse(parsed.headers['rtp-info'], RTPrange);

        if (this.flvmux) {
          /* If the flvmux have been initialized don't do it again.
             this is probably a resume after pause */
          break;
        }

        /* Set actual offset from the stream */
        this.startOptions.offset = rtpTiming.range.from;

        this.flvmux = new FLVMux(this.sdp);
        var analu:ANALU = new ANALU();
        var aaac:AAAC = new AAAC(sdp);
        var apcma:APCMA = new APCMA();

        this.addEventListener("VIDEO_H264_PACKET", analu.onRTPPacket);
        this.addEventListener("AUDIO_MPEG4-GENERIC_PACKET", aaac.onRTPPacket);
        this.addEventListener("AUDIO_PCMA_PACKET", apcma.onRTPPacket);
        analu.addEventListener(NALU.NEW_NALU, flvmux.onNALU);
        aaac.addEventListener(AACFrame.NEW_FRAME, flvmux.onAACFrame);
        apcma.addEventListener(PCMAFrame.NEW_FRAME, flvmux.onPCMAFrame);

        if (this.sdp.getMediaBlockList().length == 2) {
          var flvSync:FLVSync = new FLVSync();

          flvmux.addEventListener(FLVTag.NEW_FLV_TAG, flvSync.onFlvTag);
          flvSync.addEventListener(FLVTag.NEW_FLV_TAG, this.onFlvTag);
        } else {
          flvmux.addEventListener(FLVTag.NEW_FLV_TAG, this.onFlvTag);
        }

        /* Start Keep-alive routine */
        kaTimer.reset();
        kaTimer.addEventListener(TimerEvent.TIMER, keepAlive);
        kaTimer.start();
        break;

      case STATE_PLAYING:
        Logger.log("RTSPClient: STATE_PLAYING");
        break;

      case STATE_PAUSE:
        Logger.log("RTSPClient: STATE_PAUSE");
        state = STATE_PAUSED;
        this.bcTimer.stop();

        /* The ClientEvent must be sent here as we closed the NetStream to avoid long buffering in `pause` */
        dispatchEvent(new ClientEvent(ClientEvent.PAUSED, { 'reason': 'user' }));
        break;

      case STATE_TEARDOWN:
        Logger.log('RTSPClient: STATE_TEARDOWN');
        break;
      }

      if (0 < data.bytesAvailable) {
        onData(null);
      }
    }

    private function onInterleavedData():void {
      handle.readBytes(data, data.length);

      if (data.bytesAvailable < 4) {
        /* Not enough data even for interleaved header. Try again when
           more data is available */
        return;
      }

      if (-1 == rtpLength && 0x24 === data[0]) {
        /* This is the beginning of a new RTP package. We can't read data
           from buffer here, as we may not have enough for complete RTP packet
           and we need to be able to determine that this is an interleaved
           packet when `onData` is called again. */
        rtpChannel = data[1];
        rtpLength = data[2] << 8 | data[3];
      }

      if (data.bytesAvailable < rtpLength + 4) { /* add 4 for interleaved header */
        /* The complete RTP package is not here yet, wait for more data */
        return;
      }

      /* Discard the interleaved header. It was extracted previously. */
      data.readUnsignedInt();

      var pkgData:ByteArray = new ByteArray();
      data.readBytes(pkgData, 0, rtpLength);

      if (rtpChannel === 0 || rtpChannel === 2) {
        /* We're discarding the RTCP counter parts for now */
        var rtppkt:RTP = new RTP(pkgData, sdp, rtpTiming);
        dispatchEvent(rtppkt);
      }

      requestReset();

      if (0 < data.bytesAvailable) {
        onData(null);
      }
    }

    private function supportCommand(command:String):Boolean {
      return (-1 !== this.methods.indexOf(command));
    }

    private function getSetupURL(block:Object = null):* {
      var sessionBlock:Object = sdp.getSessionBlock();
      if (url.isAbsolute(block.control)) {
        return block.control;
      } else if (url.isAbsolute(sessionBlock.control + block.control)) {
        return sessionBlock.control + block.control;
      } else if (url.isAbsolute(contentBase + block.control)) {
        /* Should probably check session level control before this */
        return contentBase + block.control;
      }

      Logger.log('Can\'t determine track URL from ' +
            'block.control:' + block.control + ', ' +
            'session.control:' + sessionBlock.control + ', and ' +
            'content-base:' + contentBase);
      ErrorManager.dispatchError(824, null, true);
    }

    private function getControlURL():String {
      var sessCtrl:String = sdp.getSessionBlock().control;
      var u:String = sessCtrl;
      if (url.isAbsolute(u)) {
        return u;
      } else if (!u || '*' === u) {
        return contentBase;
      } else {
        return contentBase + u; /* If content base is not set, this will be session control only only */
      }

      Logger.log('Can\'t determine control URL from ' +
              'session.control:' + sessionBlock.control + ', and ' +
              'content-base:' + contentBase);
      ErrorManager.dispatchError(824, null, true);
    }

    private function sendOptionsReq():void {
      state = STATE_OPTIONS;
      var req:String =
        "OPTIONS * RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        "\r\n";
      Logger.log('RTSP OUT:', req);
      handle.writeUTFBytes(req);

      prevMethod = sendOptionsReq;
    }

    private function sendDescribeReq():void {
      state = STATE_DESCRIBE;
      var u:String = 'rtsp://' + urlParsed.host + urlParsed.urlpath;
      var req:String =
        "DESCRIBE " + u + " RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        "Accept: application/sdp\r\n" +
        auth.authorizationHeader("DESCRIBE", authState, authOpts, urlParsed, digestNC++) +
        "\r\n";
      handle.writeUTFBytes(req);
      Logger.log('RTSP OUT:', req);

      prevMethod = sendDescribeReq;
    }

    private function sendSetupReq(block:Object):void {
      state = STATE_SETUP;
      var interleavedChannels:String = interleaveChannelIndex++ + "-" + interleaveChannelIndex++;
      var setupUrl:String = getSetupURL(block);

      Logger.log('Setting up track: ' + setupUrl);
      var req:String =
        "SETUP " + setupUrl + " RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        (session ? ("Session: " + session + "\r\n") : "") +
        "Transport: RTP/AVP/TCP;unicast;interleaved=" + interleavedChannels + "\r\n" +
        auth.authorizationHeader("SETUP", authState, authOpts, urlParsed, digestNC++) +
        "Date: " + new Date().toUTCString() + "\r\n" +
        "\r\n";
      handle.writeUTFBytes(req);
      Logger.log('RTSP OUT:', req);

      prevMethod = sendSetupReq;
    }

    private function sendPlayReq(offset:Number = -1):void {
      var req:String =
        "PLAY " + getControlURL() + " RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        "Session: " + session + "\r\n";
      if (offset >= 0) {
        req += "Range: npt=" + (offset / 1000) + "-\r\n";
      }
      req += auth.authorizationHeader("PLAY", authState, authOpts, urlParsed, digestNC++) +
        "\r\n";
      handle.writeUTFBytes(req);
      Logger.log('RTSP OUT:', req);

      prevMethod = sendPlayReq;
    }

    private function sendGetParamReq():void {
      var req:String =
        "GET_PARAMETER " + getControlURL() + " RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        "Session: " + session + "\r\n" +
        auth.authorizationHeader("GET_PARAMETER", authState, authOpts, urlParsed, digestNC++) +
        "\r\n";
      Logger.log('RTSP OUT:', req);
      handle.writeUTFBytes(req);

      prevMethod = sendGetParamReq;
    }

    private function sendPauseReq():void {
      if (!this.supportCommand("PAUSE")) {
        ErrorManager.dispatchError(825, null, true);
      }

      var req:String =
        "PAUSE " + getControlURL() + " RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        "Session: " + session + "\r\n" +
        auth.authorizationHeader("PAUSE", authState, authOpts, urlParsed, digestNC++) +
        "\r\n";
      handle.writeUTFBytes(req);
      Logger.log('RTSP OUT:', req);

      prevMethod = sendPauseReq;
    }

    private function sendTeardownReq():void {
      state = STATE_TEARDOWN;
      var req:String =
        "TEARDOWN " + getControlURL() + " RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        "Session: " + session + "\r\n" +
        auth.authorizationHeader("TEARDOWN", authState, authOpts, urlParsed, digestNC++) +
        "\r\n";

      handle.writeUTFBytes(req);
      Logger.log('RTSP OUT:', req);

      prevMethod = sendTeardownReq;
    }

    private function keepAlive(event:TimerEvent):void {
      sendGetParamReq();
    }

    private function onAsyncError(event:AsyncErrorEvent):void {
      bcTimer.stop();
      ErrorManager.dispatchError(728);
    }

    private function onIOError(event:IOErrorEvent):void {
      bcTimer.stop();
      ErrorManager.dispatchError(729, [event.text]);
    }

    private function onSecurityError(event:SecurityErrorEvent):void {
      bcTimer.stop();
      ErrorManager.dispatchError(730, [event.text]);
    }

    private function onNetStatusError(event:NetStatusEvent):void {
      if (event.info.status === 'error') {
        bcTimer.stop();
      }
    }

    private function bcTimerHandler(e:TimerEvent):void {
      Logger.log("RTSP stream timed out", { bufferEmpty: bufferEmpty, frameBuffer: this.streamBuffer.length, state: currentState });
      connectionBroken = true;

      this.handle.disconnect();

      nc.removeEventListener(AsyncErrorEvent.ASYNC_ERROR, onAsyncError);
      nc.removeEventListener(IOErrorEvent.IO_ERROR, onIOError);
      nc.removeEventListener(NetStatusEvent.NET_STATUS, onNetStatusError);
      nc.removeEventListener(SecurityErrorEvent.SECURITY_ERROR, onSecurityError);

      if (evoStream) {
        streamEnded = true;
      }

      /* If the stream has ended don't dispatch error, evo stream doesn't give
       * us any information about when the stream ends so assume this is the
       * proper end of the stream */
      if (!streamEnded) {
        ErrorManager.dispatchError(827);
      }

      if (bufferEmpty && this.streamBuffer.length === 0) {
        dispatchEvent(new ClientEvent(ClientEvent.STOPPED));
        this.ns.dispose();
      }
    }
  }
}
