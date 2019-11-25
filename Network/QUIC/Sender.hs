{-# LANGUAGE OverloadedStrings #-}

module Network.QUIC.Sender where

import Control.Concurrent
import Control.Concurrent.STM
import qualified Data.ByteString as B

import Network.QUIC.Connection
import Network.QUIC.Imports
import Network.QUIC.Transport
import Network.QUIC.Types

----------------------------------------------------------------

cryptoFrame :: Connection -> PacketType -> CryptoData -> IO [Frame]
cryptoFrame conn pt crypto = do
    let len = B.length crypto
    off <- modifyCryptoOffset conn pt len
    case pt of
      Initial   -> return (Crypto off crypto : replicate 963 Padding)
      Handshake -> return [Crypto off crypto]
      Short     -> return [Crypto off crypto]
      _         -> error "cryptoFrame"

----------------------------------------------------------------

construct :: Connection -> Segment -> PacketType -> [Frame] -> Token -> IO ByteString
construct conn seg pt frames token = do
    peercid <- getPeerCID conn
    mbin0 <- constructAckPacket pt peercid
    case mbin0 of
      Nothing   -> constructTargetPacket peercid
      Just bin0 -> do
          bin1 <- constructTargetPacket peercid
          return $ bin0 `B.append` bin1
  where
    mycid = myCID conn
    constructAckPacket Handshake peercid = do
        pns <- getPNs conn Initial
        if nullPNs pns then
            return Nothing
          else do
            mypn <- getPacketNumber conn
            let ackFrame = Ack (toAckInfo $ fromPNs pns) 0
                pkt = InitialPacket currentDraft peercid mycid "" mypn [ackFrame]
            keepSegment conn mypn A Initial pns
            Just <$> encodePacket conn pkt
    constructAckPacket Short peercid = do
        pns <- getPNs conn Handshake
        if nullPNs pns then
            return Nothing
          else do
            mypn <- getPacketNumber conn
            let ackFrame = Ack (toAckInfo $ fromPNs pns) 0
                pkt = HandshakePacket currentDraft peercid mycid mypn [ackFrame]
            keepSegment conn mypn A Handshake pns
            Just <$> encodePacket conn pkt
    constructAckPacket _ _ = return Nothing
    constructTargetPacket peercid = do
        mypn <- getPacketNumber conn
        pns <- getPNs conn pt
        let frames'
              | null pns  = frames
              | otherwise = Ack (toAckInfo $ fromPNs pns) 0 : frames
        let pkt = case pt of
              Initial   -> InitialPacket   currentDraft peercid mycid token mypn frames'
              Handshake -> HandshakePacket currentDraft peercid mycid       mypn frames'
              Short     -> ShortPacket                  peercid             mypn frames'
              _         -> error "construct"
        keepSegment conn mypn seg pt pns
        encodePacket conn pkt

----------------------------------------------------------------

sender :: Connection -> IO ()
sender conn = loop
  where
    loop = forever $ do
        seg <- atomically $ readTQueue $ outputQ conn
        case seg of
          H pt cdat token -> do
              frames <- cryptoFrame conn pt cdat
              bs <- construct conn seg pt frames token
              connSend conn bs
          C pt frames -> do
              bs <- construct conn seg pt frames emptyToken
              connSend conn bs
          S sid dat -> do
              bs <- construct conn seg Short [Stream sid 0 dat True] emptyToken -- fixme: off
              connSend conn bs
          _ -> return ()

----------------------------------------------------------------

resender :: Connection -> IO ()
resender conn = forever $ do
    threadDelay 25000
    -- retransQ
    segs <- updateSegment conn (MilliSeconds 25)
    mapM_ (atomically . writeTQueue (outputQ conn)) segs
