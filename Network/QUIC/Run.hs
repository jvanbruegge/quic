{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.QUIC.Run (
    runQUICClient
  , runQUICServer
  , stopQUICServer
  , clientCertificateChain
  ) where

import Control.Concurrent
import Control.Concurrent.Async
import qualified Control.Exception as E
import Data.X509 (CertificateChain)
import Foreign.Marshal.Alloc
import Foreign.Ptr
import qualified Network.Socket as NS
import System.Log.FastLogger

import Network.QUIC.Client
import Network.QUIC.Closer
import Network.QUIC.Config
import Network.QUIC.Connection
import Network.QUIC.Connector
import Network.QUIC.Crypto
import Network.QUIC.Exception
import Network.QUIC.Handshake
import Network.QUIC.Imports
import Network.QUIC.Logger
import Network.QUIC.Packet
import Network.QUIC.Parameters
import Network.QUIC.QLogger
import Network.QUIC.Qlog
import Network.QUIC.Receiver
import Network.QUIC.Recovery
import Network.QUIC.Sender
import Network.QUIC.Server
import Network.QUIC.Socket
import Network.QUIC.Types

----------------------------------------------------------------

data ConnRes = ConnRes Connection SendBuf Receive AuthCIDs (IO ())

connResConnection :: ConnRes -> Connection
connResConnection (ConnRes conn _ _ _ _) = conn

----------------------------------------------------------------

-- | Running a QUIC client.
runQUICClient :: ClientConfig -> (Connection -> IO a) -> IO a
-- Don't use handleLogUnit here because of a return value.
runQUICClient conf client = case confVersions $ ccConfig conf of
  []     -> E.throwIO NoVersionIsSpecified
  ver1:_ -> do
      ex <- E.try $ runClient conf client ver1
      case ex of
        Right v                     -> return v
        Left se@(E.SomeException e)
          | Just (NextVersion ver2) <- E.fromException se
                                    -> runClient conf client ver2
          | otherwise               -> E.throwIO e

runClient :: ClientConfig -> (Connection -> IO a) -> Version -> IO a
runClient conf client0 ver = do
    E.bracket open clse $ \(ConnRes conn send recv myAuthCIDs reader) -> do
        forkIO reader    >>= addReader conn
        forkIO timeouter >>= addTimeouter conn
        handshaker <- handshakeClient conf conn myAuthCIDs
        let client = do
                if ccUse0RTT conf then
                    wait0RTTReady conn
                  else
                    wait1RTTReady conn
                setToken conn $ resumptionToken $ ccResumption conf
                client0 conn
            ldcc = connLDCC conn
            supporters = foldr1 concurrently_ [handshaker
                                              ,sender   conn send
                                              ,receiver conn recv
                                              ,resender  ldcc
                                              ,ldccTimer ldcc
                                              ]
            runThreads = race supporters client
        E.try runThreads >>= closure conn ldcc
  where
    open = createClientConnection conf ver
    clse connRes = do
        let conn = connResConnection connRes
        setDead conn
        freeResources conn
        killReaders conn
        socks <- getSockets conn
        mapM_ NS.close socks
        join $ replaceKillTimeouter conn

createClientConnection :: ClientConfig -> Version -> IO ConnRes
createClientConnection conf@ClientConfig{..} ver = do
    (s0,sa0) <- udpClientConnectedSocket ccServerName ccPortName
    q <- newRecvQ
    sref <- newIORef [s0]
    let send buf siz = do
            s:_ <- readIORef sref
            void $ NS.sendBuf s buf siz
        recv = recvClient q
    myCID   <- newCID
    peerCID <- newCID
    now <- getTimeMicrosecond
    (qLog, qclean) <- dirQLogger (confQLog ccConfig) now peerCID "client"
    let debugLog msg | ccDebugLog = stdoutLogger msg
                     | otherwise  = return ()
    debugLog $ "Original CID: " <> bhow peerCID
    let myAuthCIDs   = defaultAuthCIDs { initSrcCID = Just myCID }
        peerAuthCIDs = defaultAuthCIDs { initSrcCID = Just peerCID, origDstCID = Just peerCID }
        hooks = confHooks ccConfig
    conn <- clientConnection conf ver myAuthCIDs peerAuthCIDs debugLog qLog hooks sref q
    addResource conn qclean
    initializeCoder conn InitialLevel $ initialSecrets ver peerCID
    setupCryptoStreams conn -- fixme: cleanup
    let pktSiz0 = fromMaybe 0 ccPacketSize
        pktSiz = (defaultPacketSize sa0 `max` pktSiz0) `min` maximumPacketSize sa0
    setMaxPacketSize conn pktSiz
    setInitialCongestionWindow (connLDCC conn) pktSiz
    setAddressValidated conn
    let reader = readerClient (confVersions ccConfig) s0 conn -- dies when s0 is closed.
    return $ ConnRes conn send recv myAuthCIDs reader

----------------------------------------------------------------

-- | Running a QUIC server.
--   The action is executed with a new connection
--   in a new lightweight thread.
runQUICServer :: ServerConfig -> (Connection -> IO ()) -> IO ()
runQUICServer conf server = handleLogUnit debugLog $ do
    baseThreadId <- myThreadId
    E.bracket setup teardown $ \(dispatch,_) -> forever $ do
        acc <- accept dispatch
        void $ forkIO (runServer conf server dispatch baseThreadId acc)
  where
    debugLog msg = stdoutLogger ("runQUICServer: " <> msg)
    setup = do
        dispatch <- newDispatch
        -- fixme: the case where sockets cannot be created.
        ssas <- mapM  udpServerListenSocket $ scAddresses conf
        tids <- mapM (runDispatcher dispatch conf) ssas
        ttid <- forkIO timeouter -- fixme
        return (dispatch, ttid:tids)
    teardown (dispatch, tids) = do
        clearDispatch dispatch
        mapM_ killThread tids

-- Typically, ConnectionIsClosed breaks acceptStream.
-- And the exception should be ignored.
runServer :: ServerConfig -> (Connection -> IO ()) -> Dispatch -> ThreadId -> Accept -> IO ()
runServer conf server0 dispatch baseThreadId acc =
    E.bracket open clse $ \(ConnRes conn send recv myAuthCIDs reader) ->
        handleLogUnit (debugLog conn) $ do
            forkIO reader >>= addReader conn
            handshaker <- handshakeServer conf conn myAuthCIDs
            let server = do
                    wait1RTTReady conn
                    afterHandshakeServer conn
                    server0 conn
                ldcc = connLDCC conn
                supporters = foldr1 concurrently_ [handshaker
                                                  ,sender   conn send
                                                  ,receiver conn recv
                                                  ,resender  ldcc
                                                  ,ldccTimer ldcc
                                                  ]
                runThreads = race supporters server
            E.try runThreads >>= closure conn ldcc
  where
    open = createServerConnection conf dispatch acc baseThreadId
    clse connRes = do
        let conn = connResConnection connRes
        setDead conn
        freeResources conn
        killReaders conn
        socks <- getSockets conn
        mapM_ NS.close socks
    debugLog conn msg = do
        connDebugLog conn ("runServer: " <> msg)
        qlogDebug conn $ Debug $ toLogStr msg

createServerConnection :: ServerConfig -> Dispatch -> Accept -> ThreadId
                       -> IO ConnRes
createServerConnection conf@ServerConfig{..} dispatch Accept{..} baseThreadId = do
    s0 <- udpServerConnectedSocket accMySockAddr accPeerSockAddr
    sref <- newIORef [s0]
    let send buf siz = void $ do
            s:_ <- readIORef sref
            NS.sendBuf s buf siz
        recv = recvServer accRecvQ
    let Just myCID = initSrcCID accMyAuthCIDs
        Just ocid  = origDstCID accMyAuthCIDs
    (qLog, qclean)     <- dirQLogger (confQLog scConfig) accTime ocid "server"
    (debugLog, dclean) <- dirDebugLogger scDebugLog ocid
    let hooks = confHooks scConfig
    debugLog $ "Original CID: " <> bhow ocid
    conn <- serverConnection conf accVersion accMyAuthCIDs accPeerAuthCIDs debugLog qLog hooks sref accRecvQ
    setSockAddrs conn (accMySockAddr,accPeerSockAddr)
    addResource conn qclean
    addResource conn dclean
    let cid = fromMaybe ocid $ retrySrcCID accMyAuthCIDs
    initializeCoder conn InitialLevel $ initialSecrets accVersion cid
    setupCryptoStreams conn -- fixme: cleanup
    let pktSiz = (defaultPacketSize accMySockAddr `max` accPacketSize) `min` maximumPacketSize accMySockAddr
    setMaxPacketSize conn pktSiz
    setInitialCongestionWindow (connLDCC conn) pktSiz
    debugLog $ "Packet size: " <> bhow pktSiz <> " (" <> bhow accPacketSize <> ")"
    addRxBytes conn accPacketSize
    when accAddressValidated $ setAddressValidated conn
    --
    let retried = isJust $ retrySrcCID accMyAuthCIDs
    when retried $ do
        qlogRecvInitial conn
        qlogSentRetry conn
    --
    let mgr = tokenMgr dispatch
    setTokenManager conn mgr
    --
    setBaseThreadId conn baseThreadId
    --
    setRegister conn accRegister accUnregister
    accRegister myCID conn
    addResource conn $ do
        myCIDs <- getMyCIDs conn
        mapM_ accUnregister myCIDs
    --
    let reader = readerServer s0 conn -- dies when s0 is closed.
    return $ ConnRes conn send recv accMyAuthCIDs reader

afterHandshakeServer :: Connection -> IO ()
afterHandshakeServer conn = handleLogT logAction $ do
    --
    cidInfo <- getNewMyCID conn
    register <- getRegister conn
    register (cidInfoCID cidInfo) conn
    --
    cryptoToken <- generateToken =<< getVersion conn
    mgr <- getTokenManager conn
    token <- encryptToken mgr cryptoToken
    let ncid = NewConnectionID cidInfo 0
    sendFrames conn RTT1Level [NewToken token,ncid,HandshakeDone]
  where
    logAction msg = connDebugLog conn $ "afterHandshakeServer: " <> msg

-- | Stopping the base thread of the server.
stopQUICServer :: Connection -> IO ()
stopQUICServer conn = getBaseThreadId conn >>= killThread

----------------------------------------------------------------

closure :: Connection -> LDCC -> Either QUICException (Either () a) -> IO a
closure _    _    (Right (Left ())) = E.throwIO MustNotReached
closure conn ldcc (Right (Right x)) = do
    closure' conn ldcc $ ConnectionClose NoError 0 ""
    return x
closure conn ldcc (Left e@(TransportErrorIsSent err desc)) = do
    closure' conn ldcc $ ConnectionClose err 0 desc
    E.throwIO e
closure conn ldcc (Left e@(ApplicationProtocolErrorIsSent err desc)) = do
    closure' conn ldcc $ ConnectionCloseApp err desc
    E.throwIO e
closure _    _    (Left e) = E.throwIO e

closure' :: Connection -> LDCC -> Frame -> IO ()
closure' conn ldcc frame = do
    killReaders conn
    killTimeouter <- replaceKillTimeouter conn
    socks@(s:_) <- clearSockets conn
    let bufsiz = maximumUdpPayloadSize
    sendBuf <- mallocBytes (bufsiz * 3)
    lvl0 <- getEncryptionLevel conn
    let lvl | lvl0 == RTT0Level = InitialLevel
            | otherwise         = lvl0
    header <- mkHeader conn lvl
    mypn <- nextPacketNumber conn
    let plain = Plain (Flags 0) mypn [frame] 0
        ppkt = PlainPacket header plain
    (siz,_) <- encodePlainPacket conn sendBuf bufsiz ppkt Nothing
    let recvBuf = sendBuf `plusPtr` (bufsiz * 2)
        recv = NS.recvBuf s recvBuf bufsiz
        send = NS.sendBuf s sendBuf siz
        hook = onCloseCompleted $ connHooks conn
    now <- getTimeMicrosecond
    qlogSent conn ppkt now
    pto <- getPTO ldcc
    void $ forkFinally (closer pto send recv hook) $ \_ -> do
        free sendBuf
        mapM_ NS.close socks
        killTimeouter

----------------------------------------------------------------

-- | Getting a certificate chain.
clientCertificateChain :: Connection -> IO (Maybe CertificateChain)
clientCertificateChain conn
  | isClient conn = return Nothing
  | otherwise     = getCertificateChain conn

defaultPacketSize :: NS.SockAddr -> Int
defaultPacketSize NS.SockAddrInet6{} = defaultQUICPacketSizeForIPv6
defaultPacketSize _                  = defaultQUICPacketSizeForIPv4

maximumPacketSize :: NS.SockAddr -> Int
maximumPacketSize NS.SockAddrInet6{} = 1500 - 40 - 8 -- fixme
maximumPacketSize _                  = 1500 - 20 - 8 -- fixme
