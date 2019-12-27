{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE PatternGuards #-}

module Network.QUIC.Core where

import Control.Concurrent
import Control.Concurrent.STM
import qualified Control.Exception as E
import Data.IORef
import qualified Network.Socket as NS
import qualified Network.Socket.ByteString as NSB
import Network.TLS.QUIC
import System.Timeout

import Network.QUIC.Config
import Network.QUIC.Connection
import Network.QUIC.Handshake
import Network.QUIC.Imports
import Network.QUIC.Packet
import Network.QUIC.Receiver
import Network.QUIC.Route
import Network.QUIC.Sender
import Network.QUIC.Socket
import Network.QUIC.TLS
import Network.QUIC.Types

----------------------------------------------------------------

data QUICClient = QUICClient {
    clientConfig :: ClientConfig
  }

data QUICServer = QUICServer {
    serverConfig :: ServerConfig
  , serverRoute  :: ServerRoute
  }

----------------------------------------------------------------

withQUICClient :: ClientConfig -> (QUICClient -> IO a) -> IO a
withQUICClient conf body = do
    let qc = QUICClient conf
    body qc

connect :: QUICClient -> IO Connection
connect QUICClient{..} = E.handle tlserr $ do
    s <- udpClientConnectedSocket (ccServerName clientConfig) (ccPortName clientConfig)
    setup s `E.onException` NS.close s
  where
    setup s = do
        connref <- newIORef Nothing
        let send bss = void $ NSB.sendMany s bss
            recv     = recvClient s connref
            cls      = NS.close s
        myCID   <- newCID
        peerCID <- newCID
        conn <- clientConnection clientConfig myCID peerCID send recv cls
        setToken conn $ resumptionToken $ ccResumption clientConfig
        setCryptoOffset conn InitialLevel 0
        setCryptoOffset conn HandshakeLevel 0
        setCryptoOffset conn RTT1Level 0
        setStreamOffset conn 0 0 -- fixme
        tid0 <- forkIO (sender   conn `E.catch` reportError)
        tid1 <- forkIO (receiver conn `E.catch` reportError)
        tid2 <- forkIO (resender conn `E.catch` reportError)
        setThreadIds conn [tid0,tid1,tid2]
        writeIORef connref $ Just conn
        handshakeClient clientConfig conn
        setConnectionState conn Open
        return conn
    tlserr e = E.throwIO $ HandshakeFailed $ show $ errorToAlertDescription e

reportError :: E.SomeException -> IO ()
reportError e
  | Just E.ThreadKilled <- E.fromException e = return ()
  | otherwise                                = print e

recvClient :: NS.Socket -> IORef (Maybe Connection) -> IO [CryptPacket]
recvClient s connref = do
    pkts <- NSB.recv s 2048 >>= decodePackets
    catMaybes <$> mapM go pkts
  where
    go (PacketIV _)   = return Nothing
    go (PacketIC pkt) = return $ Just pkt
    go (PacketIR (RetryPacket ver dCID sCID oCID token))  = do
        -- The packet number of first crypto frame is 0.
        -- This ensures that retry can be accepted only once.
        mconn <- readIORef connref
        case mconn of
          Nothing   -> return ()
          Just conn -> do
              let localCID = myCID conn
              remoteCID <- getPeerCID conn
              when (dCID == localCID && oCID == remoteCID) $ do
                  mr <- releaseOutput conn 0
                  case mr of
                    Just (Retrans (OutHndClientHello cdat mEarydata) _ _) -> do
                        setPeerCID conn sCID
                        setInitialSecrets conn $ initialSecrets ver sCID
                        setToken conn token
                        setCryptoOffset conn InitialLevel 0
                        setRetried conn True
                        atomically $ writeTQueue (outputQ conn) $ OutHndClientHello cdat mEarydata
                    _ -> return ()
        return Nothing

----------------------------------------------------------------

withQUICServer :: ServerConfig -> (QUICServer -> IO ()) -> IO ()
withQUICServer conf body = do
    route <- newServerRoute
    ssas <- mapM  udpServerListenSocket $ scAddresses conf
    tids <- mapM (runRouter route) ssas
    let qs = QUICServer conf route
    body qs `E.finally` mapM_ killThread tids
  where
    runRouter route ssa@(s,_) = forkFinally (router conf route ssa) (\_ -> NS.close s)

accept :: QUICServer -> IO Connection
accept QUICServer{..} = E.handle tlserr $ do
    Accept myCID peerCID oCID mysa peersa q register unregister <- atomically $ readTQueue $ acceptQueue serverRoute
    s <- udpServerConnectedSocket mysa peersa
    let setup = do
            let send bss = void $ NSB.sendMany s bss
                recv = do
                    mpkt <- atomically $ tryReadTQueue q
                    case mpkt of
                      Nothing  -> NSB.recv s 2048 >>= decodeCryptPackets
                      Just pkt -> return [pkt]
                cls = NS.close s
            conn <- serverConnection serverConfig myCID peerCID oCID send recv cls
            setCryptoOffset conn InitialLevel 0
            setCryptoOffset conn HandshakeLevel 0
            setCryptoOffset conn RTT1Level 0
            setStreamOffset conn 0 0 -- fixme
            tid0 <- forkIO $ sender conn
            tid1 <- forkIO $ receiver conn
            tid2 <- forkIO $ resender conn
            setThreadIds conn [tid0,tid1,tid2]
            handshakeServer serverConfig oCID conn
            setServerRoleInfo conn register unregister
            register myCID
            setConnectionState conn Open
            return conn
    setup `E.onException` NS.close s
  where
    tlserr e = E.throwIO $ HandshakeFailed $ show $ errorToAlertDescription e

----------------------------------------------------------------

close :: Connection -> IO ()
close conn = do
    unless (isClient conn) $ do
        unregister <- getUnregister conn
        unregister $ myCID conn
    setConnectionState conn $ Closing (CloseState False False)
    let frames = [ConnectionCloseQUIC NoError 0 ""]
    atomically $ writeTQueue (outputQ conn) $ OutControl RTT1Level frames
    setCloseSent conn
    void $ timeout 100000 $ waitClosed conn -- fixme: timeout
    clearThreads conn
    -- close the socket after threads reading/writing the socket die.
    connClose conn
