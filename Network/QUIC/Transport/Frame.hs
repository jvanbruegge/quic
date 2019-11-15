module Network.QUIC.Transport.Frame where

import qualified Data.ByteString as B

import Network.QUIC.Imports
import Network.QUIC.Transport.Error
import Network.QUIC.Transport.Integer
import Network.QUIC.Transport.Types

----------------------------------------------------------------

encodeFrames :: [Frame] -> IO ByteString
encodeFrames frames = withWriteBuffer 2048 $ \wbuf ->
  mapM_ (encodeFrame wbuf) frames

encodeFrame :: WriteBuffer -> Frame -> IO ()
encodeFrame wbuf Padding = write8 wbuf 0x00
encodeFrame wbuf Ping = write8 wbuf 0x01
encodeFrame wbuf (Ack largest delay range1 ranges) = do
    write8 wbuf 0x02
    encodeInt' wbuf largest
    encodeInt' wbuf $ fromIntegral delay
    encodeInt' wbuf $ fromIntegral $ length ranges
    encodeInt' wbuf $ fromIntegral range1
    -- fixme: ranges
encodeFrame wbuf (Crypto off cdata) = do
    write8 wbuf 0x06
    encodeInt' wbuf $ fromIntegral off
    encodeInt' wbuf $ fromIntegral $ B.length cdata
    copyByteString wbuf cdata
encodeFrame wbuf (NewToken _) = do
    write8 wbuf 0x07
    undefined
encodeFrame wbuf (Stream sid _off dat _fin) = do
    -- fixme
    write8 wbuf (0x08 .|. 0x02 .|. 0x01)
    encodeInt' wbuf sid
    encodeInt' wbuf $ fromIntegral $ B.length dat
    copyByteString wbuf dat
encodeFrame wbuf NewConnectionID{} = do
    write8 wbuf 0x18
    undefined
encodeFrame wbuf (ConnectionCloseQUIC err ftyp reason) = do
    write8 wbuf 0x1c
    encodeInt' wbuf $ fromIntegral $ fromTransportError err
    encodeInt' wbuf $ fromIntegral ftyp
    encodeInt' wbuf $ fromIntegral $ B.length reason
    copyByteString wbuf reason
encodeFrame wbuf (ConnectionCloseApp err reason) = do
    write8 wbuf 0x1d
    encodeInt' wbuf $ fromIntegral $ fromTransportError err
    encodeInt' wbuf $ fromIntegral $ B.length reason
    copyByteString wbuf reason
encodeFrame _ _ = undefined

----------------------------------------------------------------

decodeFrames :: ByteString -> IO [Frame]
decodeFrames bs = withReadBuffer bs $ loop id
  where
    loop frames rbuf = do
        ok <- (>= 1) <$> remainingSize rbuf
        if ok then do
            frame <- decodeFrame rbuf
            loop (frames . (frame:)) rbuf
          else
            return $ frames []

decodeFrame :: ReadBuffer -> IO Frame
decodeFrame rbuf = do
    ftyp <- fromIntegral <$> decodeInt' rbuf
    case ftyp :: FrameType of
      0x00 -> return Padding
      0x01 -> return Ping
      0x02 -> decodeAckFrame rbuf
      0x06 -> decodeCryptoFrame rbuf
      0x07 -> decodeNewToken rbuf
      x | 0x08 <= x && x <= 0x0f -> do
              let off = testBit x 3
                  len = testBit x 2
                  fin = testBit x 1
              decodeStreamFrame rbuf off len fin
      0x18 -> decodeNewConnectionID rbuf
      0x1c -> decodeConnectionCloseFrameQUIC rbuf
      0x1d -> decodeConnectionCloseFrameApp rbuf
      _x   -> error $ show _x

decodeCryptoFrame :: ReadBuffer -> IO Frame
decodeCryptoFrame rbuf = do
    off <- fromIntegral <$> decodeInt' rbuf
    len <- fromIntegral <$> decodeInt' rbuf
    cdata <- extractByteString rbuf len
    return $ Crypto off cdata

decodeAckFrame :: ReadBuffer -> IO Frame
decodeAckFrame rbuf = do
    largest <- decodeInt' rbuf
    delay   <- fromIntegral <$> decodeInt' rbuf
    _count  <- (fromIntegral <$> decodeInt' rbuf) :: IO Int
    range1  <- fromIntegral <$> decodeInt' rbuf
    -- fixme: ranges
    return $ Ack largest delay range1 []

decodeNewToken :: ReadBuffer -> IO Frame
decodeNewToken rbuf = do
    len <- fromIntegral <$> decodeInt' rbuf
    token <- extractByteString rbuf len
    return $ NewToken token

decodeStreamFrame :: ReadBuffer -> Bool -> Bool -> Bool -> IO Frame
decodeStreamFrame rbuf hasOff hasLen fin = do
    sID <- decodeInt' rbuf
    off <- if hasOff then
             fromIntegral <$> decodeInt' rbuf
           else
             return 0
    dat <- if hasLen then do
             len <- fromIntegral <$> decodeInt' rbuf
             extractByteString rbuf len
           else do
             len <- remainingSize rbuf
             extractByteString rbuf len
    return $ Stream sID off dat fin

decodeConnectionCloseFrameQUIC  :: ReadBuffer -> IO Frame
decodeConnectionCloseFrameQUIC rbuf = do
    err    <- toTransportError . fromIntegral <$> decodeInt' rbuf
    ftyp   <- fromIntegral <$> decodeInt' rbuf
    len    <- fromIntegral <$> decodeInt' rbuf
    reason <- extractByteString rbuf len
    return $ ConnectionCloseQUIC err ftyp reason

decodeConnectionCloseFrameApp  :: ReadBuffer -> IO Frame
decodeConnectionCloseFrameApp rbuf = do
    err    <- toTransportError . fromIntegral <$> decodeInt' rbuf
    len    <- fromIntegral <$> decodeInt' rbuf
    reason <- extractByteString rbuf len
    return $ ConnectionCloseApp err reason

decodeNewConnectionID :: ReadBuffer -> IO Frame
decodeNewConnectionID rbuf = do
    seqNum <- fromIntegral <$> decodeInt' rbuf
    rpt <- fromIntegral <$> decodeInt' rbuf
    cidLen <- fromIntegral <$> read8 rbuf
    cID <- CID <$> extractByteString rbuf cidLen
    token <- extractByteString rbuf 16
    return $ NewConnectionID seqNum rpt cID token
