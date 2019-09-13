{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.IORef
import Network.QUIC
import Network.Run.UDP
import Network.Socket
import Network.Socket.ByteString
import Network.TLS hiding (Context)
import System.Environment

main :: IO ()
main = do
    [serverName,port] <- getArgs
    runUDPClient serverName port $ quicClient serverName

quicClient :: String -> Socket -> SockAddr -> IO ()
quicClient serverName s peerAddr = do
    let conf = defaultClientConfig {
            ccVersion    = Draft22
          , ccServerName = serverName
          , ccALPN       = return $ Just ["h3-22"]
          }
    ctx <- clientContext conf
    (iniBin, exts) <- createClientInitial ctx
    void $ sendTo s iniBin peerAddr

    (shBin, _) <- recvFrom s 2048
    eefin0 <- handleServerInitial ctx shBin exts

    eefins <- recvEefin1Bin ctx s eefin0

    iniBin2 <- createClientInitial2 ctx eefins
    -- xxx creating ack
    void $ sendTo s iniBin2 peerAddr


exampleParameters :: Parameters
exampleParameters = defaultParameters {
    maxStreamDataBidiLocal  =  262144
  , maxStreamDataBidiRemote =  262144
  , maxStreamDataUni        =  262144
  , maxData                 = 1048576
  , maxStreamsBidi          =       1
  , maxStreamsUni           =     100
  , idleTimeout             =   30000
  , activeConnectionIdLimit =       7
  }

createClientInitial :: Context -> IO (ByteString, Handshake13)
createClientInitial ctx = do
    let params = encodeParametersList $ diffParameters exampleParameters
    (ch, chbin) <- makeClientHello13 cparams tlsctx [ExtensionRaw 0xffa5 params]
    let frames = Crypto 0 chbin :  replicate 963 Padding
        mycid = myCID ctx
    peercid <- readIORef $ peerCID ctx
    let iniPkt = InitialPacket Draft22 peercid mycid "" 0 frames
    iniBin <- encodePacket ctx iniPkt
    return (iniBin, ch)
  where
    cparams = tlsClientParams ctx
    tlsctx = tlsConetxt ctx

handleServerInitial :: Context -> ByteString -> Handshake13 -> IO ByteString
handleServerInitial ctx shBin ch = do
    (InitialPacket Draft22 _ _ _ _ [Crypto _ sh, _ack], eefinBin) <- decodePacket ctx shBin
    (cipher, handSecret, _resuming) <- handleServerHello13 cparams tlsctx ch sh
    setCipher ctx cipher
    writeIORef (handshakeSecret ctx) $ Just handSecret
    (HandshakePacket Draft22 _ _ _ [Crypto _ eefin0], _) <- decodePacket ctx eefinBin

    return eefin0
  where
    cparams = tlsClientParams ctx
    tlsctx = tlsConetxt ctx

recvEefin1Bin :: Context -> Socket -> ByteString -> IO ByteString
recvEefin1Bin ctx s bs = do
    check <- handshakeCheck finished bs Start
    case check of
      Done -> return bs
      cont -> loop cont (bs :)
  where
    finished = 20
    loop cont build = do
        (bin, _) <- recvFrom s 2048
        (HandshakePacket Draft22 _ _ _ [Crypto _ eefin], _fixme) <- decodePacket ctx bin
        check <- handshakeCheck finished eefin cont
        let build' = build . (eefin :)
        case check of
          Done -> return $ B.concat $ build' []
          cont' -> loop cont' build'

createClientInitial2 :: Context -> ByteString -> IO ByteString
createClientInitial2 ctx eefin = do
    -- makeing Initial: ACK
    Just handSecret <- readIORef $ handshakeSecret ctx
    (crypto, appSecret) <- makeClientFinished13 cparams tlsctx eefin handSecret False
    -- making Handshake: crypto + ACK
    writeIORef (applicationSecret ctx) $ Just appSecret
    -- making 1-RTT: stream
    return crypto
  where
    cparams = tlsClientParams ctx
    tlsctx = tlsConetxt ctx
