{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Network.QUIC.Connection.Crypto (
    setEncryptionLevel
  , waitEncryptionLevel
  , putOffCrypto
  --
  , getCipher
  , setCipher
  , getTLSMode
  , getApplicationProtocol
  , setNegotiated
  --
  , dropSecrets
  --
  , initializeCoder
  , initializeCoder1RTT
  , updateCoder1RTT
  , getCoder
  , getProtector
  --
  , getCurrentKeyPhase
  , setCurrentKeyPhase
  ) where

import Control.Concurrent.STM
import Network.TLS.QUIC

import Network.QUIC.Connection.Misc
import Network.QUIC.Connection.Types
import Network.QUIC.Connector
import Network.QUIC.Crypto
import Network.QUIC.CryptoFusion
import Network.QUIC.Imports
import Network.QUIC.Types

----------------------------------------------------------------

setEncryptionLevel :: Connection -> EncryptionLevel -> IO ()
setEncryptionLevel conn@Connection{..} lvl = do
    (_, q) <- getSockInfo conn
    atomically $ do
        writeTVar (encryptionLevel connState) lvl
        case lvl of
          HandshakeLevel -> do
              readTVar (pendingQ ! RTT0Level)      >>= mapM_ (prependRecvQ q)
              readTVar (pendingQ ! HandshakeLevel) >>= mapM_ (prependRecvQ q)
          RTT1Level      ->
              readTVar (pendingQ ! RTT1Level)      >>= mapM_ (prependRecvQ q)
          _              -> return ()

putOffCrypto :: Connection -> EncryptionLevel -> ReceivedPacket -> IO ()
putOffCrypto Connection{..} lvl rpkt =
    atomically $ modifyTVar' (pendingQ ! lvl) (rpkt :)

waitEncryptionLevel :: Connection -> EncryptionLevel -> IO ()
waitEncryptionLevel Connection{..} lvl = atomically $ do
    l <- readTVar $ encryptionLevel connState
    check (l >= lvl)

----------------------------------------------------------------

getCipher :: Connection -> EncryptionLevel -> IO Cipher
getCipher Connection{..} lvl = readArray ciphers lvl

setCipher :: Connection -> EncryptionLevel -> Cipher -> IO ()
setCipher Connection{..} lvl cipher = writeArray ciphers lvl cipher

----------------------------------------------------------------

getTLSMode :: Connection -> IO HandshakeMode13
getTLSMode Connection{..} = handshakeMode <$> readIORef negotiated

getApplicationProtocol :: Connection -> IO (Maybe NegotiatedProtocol)
getApplicationProtocol Connection{..} = applicationProtocol <$> readIORef negotiated

setNegotiated :: Connection -> HandshakeMode13 -> Maybe NegotiatedProtocol -> ApplicationSecretInfo -> IO ()
setNegotiated Connection{..} mode mproto appSecInf =
    writeIORef negotiated Negotiated {
        handshakeMode = mode
      , applicationProtocol = mproto
      , applicationSecretInfo = appSecInf
      }

----------------------------------------------------------------

dropSecrets :: Connection -> EncryptionLevel -> IO ()
dropSecrets conn@Connection{..} lvl = do
    coder <- getCoder conn lvl False
    writeArray coders lvl initialCoder
    fusionFreeContext $ fctxTX coder
    fusionFreeContext $ fctxRX coder
    Protector supp unp <- getProtector conn lvl
    writeArray protectors lvl initialProtector { unprotect = unp }
    fusionFreeSupplement supp

----------------------------------------------------------------

initCoder :: Connection -> EncryptionLevel -> TrafficSecrets a -> IO (Coder, Protector)
initCoder conn lvl sec = do
    cipher <- getCipher conn lvl
    fctxt <- fusionNewContext
    fctxr <- fusionNewContext
    genCoder (isClient conn) cipher sec fctxt fctxr

initializeCoder :: Connection -> EncryptionLevel -> TrafficSecrets a -> IO ()
initializeCoder conn lvl sec = do
    (coder, protector) <- initCoder conn lvl sec
    writeArray (coders conn) lvl coder
    writeArray (protectors conn) lvl protector

initializeCoder1RTT :: Connection -> TrafficSecrets ApplicationSecret -> IO ()
initializeCoder1RTT conn sec = do
    initCoder1RTT False
    initCoder1RTT True
    updateCoder1RTT conn True
  where
    initCoder1RTT keyPhase = do
        (coder, protector) <- initCoder conn RTT1Level sec
        let coder1 = Coder1RTT coder sec
        writeArray (coders1RTT conn) keyPhase coder1
        writeArray (protectors conn) RTT1Level protector

updateCoder1RTT :: Connection -> Bool -> IO ()
updateCoder1RTT conn nextPhase = do
    cipher <- getCipher conn RTT1Level
    Coder1RTT coder secN <- readArray (coders1RTT conn) (not nextPhase)
    let fctxt = fctxTX coder
        fctxr = fctxRX coder
    let secN1 = updateSecret cipher secN
    coderN1 <- genCoderOnly (isClient conn) cipher secN1 fctxt fctxr
    let nextCoder = Coder1RTT coderN1 secN1
    writeArray (coders1RTT conn) nextPhase nextCoder

updateSecret :: Cipher -> TrafficSecrets ApplicationSecret -> TrafficSecrets ApplicationSecret
updateSecret cipher (ClientTrafficSecret cN, ServerTrafficSecret sN) = secN1
  where
    Secret cN1 = nextSecret cipher $ Secret cN
    Secret sN1 = nextSecret cipher $ Secret sN
    secN1 = (ClientTrafficSecret cN1, ServerTrafficSecret sN1)

genCoder :: Bool -> Cipher -> TrafficSecrets a -> FusionContext -> FusionContext -> IO (Coder, Protector)
genCoder cli cipher (ClientTrafficSecret c, ServerTrafficSecret s) fctxt fctxr = do
    fusionSetup cipher fctxt txPayloadKey txPayloadIV
    fusionSetup cipher fctxr rxPayloadKey rxPayloadIV
    let enc = fusionEncrypt fctxt
        dec = fusionDecrypt fctxr
        coder = Coder enc dec fctxt fctxr
    supp <- fusionSetupSupplement cipher txHeaderKey
    let protector = Protector supp unp
    return (coder, protector)
  where
    txSecret | cli           = Secret c
             | otherwise     = Secret s
    rxSecret | cli           = Secret s
             | otherwise     = Secret c
    txPayloadKey = aeadKey cipher txSecret
    txPayloadIV  = initialVector cipher txSecret
    txHeaderKey  = headerProtectionKey cipher txSecret
    rxPayloadKey = aeadKey cipher rxSecret
    rxPayloadIV  = initialVector cipher rxSecret
    rxHeaderKey  = headerProtectionKey cipher rxSecret
    unp = protectionMask cipher rxHeaderKey

genCoderOnly :: Bool -> Cipher -> TrafficSecrets a -> FusionContext -> FusionContext -> IO Coder
genCoderOnly cli cipher (ClientTrafficSecret c, ServerTrafficSecret s) fctxt fctxr = do
    fusionSetup cipher fctxt txPayloadKey txPayloadIV
    fusionSetup cipher fctxr rxPayloadKey rxPayloadIV
    let enc = fusionEncrypt fctxt
        dec = fusionDecrypt fctxr
        coder = Coder enc dec fctxt fctxr
    return coder
  where
    txSecret | cli           = Secret c
             | otherwise     = Secret s
    rxSecret | cli           = Secret s
             | otherwise     = Secret c
    txPayloadKey = aeadKey cipher txSecret
    txPayloadIV  = initialVector cipher txSecret
    rxPayloadKey = aeadKey cipher rxSecret
    rxPayloadIV  = initialVector cipher rxSecret

getCoder :: Connection -> EncryptionLevel -> Bool -> IO Coder
getCoder conn RTT1Level k = coder1RTT <$> readArray (coders1RTT conn) k
getCoder conn lvl       _ = readArray (coders conn) lvl

getProtector :: Connection -> EncryptionLevel -> IO Protector
getProtector conn lvl = readArray (protectors conn) lvl

----------------------------------------------------------------

getCurrentKeyPhase :: Connection -> IO (Bool, PacketNumber)
getCurrentKeyPhase Connection{..} = readIORef currentKeyPhase

setCurrentKeyPhase :: Connection -> Bool -> PacketNumber -> IO ()
setCurrentKeyPhase Connection{..} k pn = writeIORef currentKeyPhase (k, pn)
