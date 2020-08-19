{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

module Network.QUIC.Connection.Types where

import Control.Concurrent
import Control.Concurrent.STM
import qualified Crypto.Token as CT
import Data.Array.IO
import Data.X509 (CertificateChain)
import Foreign.Marshal.Alloc (mallocBytes, free)
import GHC.Event
import Network.Socket (Socket)
import Network.TLS.QUIC

import Network.QUIC.Config
import Network.QUIC.Imports
import Network.QUIC.Logger
import Network.QUIC.Parameters
import Network.QUIC.Stream
import Network.QUIC.TLS
import Network.QUIC.Types

----------------------------------------------------------------

data Role = Client | Server deriving (Eq, Show)

----------------------------------------------------------------

data ConnectionState = Handshaking
                     | ReadyFor0RTT
                     | ReadyFor1RTT
                     | Established
                     deriving (Eq, Ord, Show)

data CloseState = CloseState {
    closeSent     :: Bool
  , closeReceived :: Bool
  } deriving (Eq, Show)

----------------------------------------------------------------

dummySecrets :: TrafficSecrets a
dummySecrets = (ClientTrafficSecret "", ServerTrafficSecret "")

----------------------------------------------------------------

data RoleInfo = ClientInfo { clientInitialToken :: Token -- new or retry token
                           , resumptionInfo     :: ResumptionInfo
                           }
              | ServerInfo { tokenManager    :: ~CT.TokenManager
                           , registerCID     :: CID -> Connection -> IO ()
                           , unregisterCID   :: CID -> IO ()
                           , askRetry        :: Bool
                           , mainThreadId    :: ~ThreadId
                           , certChain       :: Maybe CertificateChain
                           }

defaultClientRoleInfo :: RoleInfo
defaultClientRoleInfo = ClientInfo {
    clientInitialToken = emptyToken
  , resumptionInfo = defaultResumptionInfo
  }

defaultServerRoleInfo :: RoleInfo
defaultServerRoleInfo = ServerInfo {
    tokenManager = undefined
  , registerCID = \_ _ -> return ()
  , unregisterCID = \_ -> return ()
  , askRetry = False
  , mainThreadId = undefined
  , certChain = Nothing
  }

-- fixme: limitation
data CIDDB = CIDDB {
    usedCIDInfo :: CIDInfo
  , cidInfos    :: [CIDInfo]
  , nextSeqNum  :: Int  -- only for mine
  } deriving (Show)

newCIDDB :: CID -> CIDDB
newCIDDB cid = CIDDB {
    usedCIDInfo = cidInfo
  , cidInfos    = [cidInfo]
  , nextSeqNum  = 1
  }
  where
    cidInfo = CIDInfo 0 cid (StatelessResetToken "")

----------------------------------------------------------------

data MigrationState = NonMigration
                    | MigrationStarted
                    | SendChallenge [PathData]
                    | RecvResponse
                    deriving (Eq, Show)

data Coder = Coder {
    encrypt :: CipherText -> ByteString -> PacketNumber -> [CipherText]
  , decrypt :: CipherText -> ByteString -> PacketNumber -> Maybe PlainText
  , protect   :: Sample -> Mask
  , unprotect :: Sample -> Mask
  }

initialCoder :: Coder
initialCoder = Coder {
    encrypt = \_ _ _ -> []
  , decrypt = \_ _ _ -> Nothing
  , protect   = \_ -> Mask ""
  , unprotect = \_ -> Mask ""
  }

----------------------------------------------------------------

data Negotiated = Negotiated {
      handshakeMode :: HandshakeMode13
    , applicationProtocol :: Maybe NegotiatedProtocol
    , applicationSecretInfo :: ApplicationSecretInfo
    }

initialNegotiated :: Negotiated
initialNegotiated = Negotiated {
      handshakeMode = FullHandshake
    , applicationProtocol = Nothing
    , applicationSecretInfo = ApplicationSecretInfo defaultTrafficSecrets
    }

----------------------------------------------------------------

-- | A quic connection to carry multiple streams.
data Connection = Connection {
    role              :: Role
  -- Actions
  , connDebugLog      :: DebugLogger
  , connQLog          :: QLogger
  , connHooks         :: Hooks
  -- WriteBuffer
  , headerBuffer      :: (Buffer,BufferSize)
  , payloadBuffer     :: (Buffer,BufferSize)
  -- Info
  , roleInfo          :: IORef RoleInfo
  , quicVersion       :: IORef Version
  -- Manage
  , connThreadId      :: ThreadId
  , killHandshakerAct :: IORef (IO ())
  , sockInfo          :: IORef (Socket,RecvQ)
  -- Mine
  , myParameters      :: Parameters
  , myCIDDB           :: IORef CIDDB
  -- Peer
  , peerParameters    :: IORef Parameters
  , peerCIDDB         :: TVar CIDDB
  -- Queues
  , inputQ            :: InputQ
  , cryptoQ           :: CryptoQ
  , outputQ           :: OutputQ
  , migrationQ        :: MigrationQ
  , shared            :: Shared
  , delayedAckCount   :: IORef Int
  , delayedAckCancel  :: IORef (IO ())
  -- State
  , connectionState   :: TVar ConnectionState
  , closeState        :: TVar CloseState
  , packetNumber      :: IORef PacketNumber      -- squeezing three to one
  , peerPacketNumber  :: IORef PacketNumber      -- for RTT1
  , spaceDiscarded    :: IOArray EncryptionLevel Bool
  , peerPacketNumbers :: IORef PeerPacketNumbers -- squeezing three to one
  , previousRTT1PPNs  :: IORef PeerPacketNumbers -- for RTT1
  , streamTable       :: IORef StreamTable
  , myStreamId        :: IORef StreamId
  , myUniStreamId     :: IORef StreamId
  , peerStreamId      :: IORef StreamId
  , flowTx            :: TVar Flow
  , flowRx            :: IORef Flow
  , migrationState    :: TVar MigrationState
  , maxPacketSize     :: IORef Int
  , minIdleTimeout    :: IORef Microseconds
  -- TLS
  , encryptionLevel   :: TVar    EncryptionLevel -- to synchronize
  , pendingQ          :: Array   EncryptionLevel (TVar [CryptPacket])
  , ciphers           :: IOArray EncryptionLevel Cipher
  , coders            :: IOArray EncryptionLevel Coder
  , negotiated        :: IORef Negotiated
  , handshakeCIDs     :: IORef AuthCIDs
  -- Resources
  , connResources     :: IORef (IO ())
  -- Recovery
  , recoveryRTT       :: IORef RTT
  , recoveryCC        :: TVar CC
  , sentPackets       :: Array EncryptionLevel (IORef SentPackets)
  , lossDetection     :: Array EncryptionLevel (IORef LossDetection)
  , timerKey          :: IORef (Maybe TimeoutKey)
  , timerInfo         :: IORef TimerInfo
  , lostCandidates    :: TVar SentPackets
  , ptoPing           :: TVar (Maybe EncryptionLevel)
  , speedingUp        :: IORef Bool
  }

makePendingQ :: IO (Array EncryptionLevel (TVar [CryptPacket]))
makePendingQ = do
    q1 <- newTVarIO []
    q2 <- newTVarIO []
    q3 <- newTVarIO []
    let lst = [(RTT0Level,q1),(HandshakeLevel,q2),(RTT1Level,q3)]
        arr = array (RTT0Level,RTT1Level) lst
    return arr

makeSentPackets :: IO (Array EncryptionLevel (IORef SentPackets))
makeSentPackets = do
    i1 <- newIORef emptySentPackets
    i2 <- newIORef emptySentPackets
    i3 <- newIORef emptySentPackets
    let lst = [(InitialLevel,i1),(HandshakeLevel,i2),(RTT1Level,i3)]
        arr = array (InitialLevel,RTT1Level) lst
    return arr

makeLossDetection :: IO (Array EncryptionLevel (IORef LossDetection))
makeLossDetection = do
    i1 <- newIORef initialLossDetection
    i2 <- newIORef initialLossDetection
    i3 <- newIORef initialLossDetection
    let lst = [(InitialLevel,i1),(HandshakeLevel,i2),(RTT1Level,i3)]
        arr = array (InitialLevel,RTT1Level) lst
    return arr

newConnection :: Role
              -> Parameters
              -> Version -> AuthCIDs -> AuthCIDs
              -> DebugLogger -> QLogger -> Hooks
              -> IORef (Socket,RecvQ)
              -> IO Connection
newConnection rl myparams ver myAuthCIDs peerAuthCIDs debugLog qLog hooks sref = do
    tvarFlowTx <- newTVarIO defaultFlow
    let hlen = maximumQUICHeaderSize
        plen = maximumUdpPayloadSize
    hbuf <- mallocBytes hlen
    pbuf <- mallocBytes plen
    let freeBufs = free hbuf >> free pbuf
    Connection rl debugLog qLog hooks (hbuf,hlen) (pbuf,plen)
        -- Info
        <$> newIORef initialRoleInfo
        <*> newIORef ver
        -- Manage
        <*> myThreadId
        <*> newIORef (return ())
        <*> return sref
        -- Mine
        <*> return myparams
        <*> newIORef (newCIDDB myCID)
        -- Peer
        <*> newIORef baseParameters
        <*> newTVarIO (newCIDDB peerCID)
        -- Queues
        <*> newTQueueIO
        <*> newTQueueIO
        <*> newTQueueIO
        <*> newTQueueIO
        <*> newShared tvarFlowTx
        <*> newIORef 0
        <*> newIORef (return ())
        -- State
        <*> newTVarIO Handshaking
        <*> newTVarIO CloseState { closeSent = False, closeReceived = False }
        <*> newIORef 0
        <*> newIORef 0
        <*> newArray (InitialLevel,RTT1Level) False
        <*> newIORef emptyPeerPacketNumbers
        <*> newIORef emptyPeerPacketNumbers
        <*> newIORef emptyStreamTable
        <*> newIORef (if isclient then 0 else 1)
        <*> newIORef (if isclient then 2 else 3)
        <*> newIORef (if isclient then 1 else 0)
        <*> return tvarFlowTx
        <*> newIORef defaultFlow { flowMaxData = initialMaxData myparams }
        <*> newTVarIO NonMigration
        <*> newIORef defaultQUICPacketSize
        <*> newIORef (milliToMicro $ maxIdleTimeout myparams)
        -- TLS
        <*> newTVarIO InitialLevel
        <*> makePendingQ
        <*> newArray (InitialLevel,RTT1Level) defaultCipher
        <*> newArray (InitialLevel,RTT1Level) initialCoder
        <*> newIORef initialNegotiated
        <*> newIORef peerAuthCIDs
        -- Resources
        <*> newIORef freeBufs
        -- Recovery
        <*> newIORef initialRTT
        <*> newTVarIO initialCC
        <*> makeSentPackets
        <*> makeLossDetection
        <*> newIORef Nothing
        <*> newIORef timerInfo0
        <*> newTVarIO emptySentPackets
        <*> newTVarIO Nothing
        <*> newIORef False
  where
    isclient = rl == Client
    initialRoleInfo
      | isclient  = defaultClientRoleInfo
      | otherwise = defaultServerRoleInfo
    Just myCID   = initSrcCID myAuthCIDs
    Just peerCID = initSrcCID peerAuthCIDs

defaultTrafficSecrets :: (ClientTrafficSecret a, ServerTrafficSecret a)
defaultTrafficSecrets = (ClientTrafficSecret "", ServerTrafficSecret "")

----------------------------------------------------------------

clientConnection :: ClientConfig
                 -> Version -> AuthCIDs -> AuthCIDs
                 -> DebugLogger -> QLogger -> Hooks
                 -> IORef (Socket,RecvQ)
                 -> IO Connection
clientConnection ClientConfig{..} ver myAuthCIDs peerAuthCIDs =
    newConnection Client params ver myAuthCIDs peerAuthCIDs
  where
    params = confParameters ccConfig

serverConnection :: ServerConfig
                 -> Version -> AuthCIDs -> AuthCIDs
                 -> DebugLogger -> QLogger -> Hooks
                 -> IORef (Socket,RecvQ)
                 -> IO Connection
serverConnection ServerConfig{..} ver myAuthCIDs peerAuthCIDs =
    newConnection Server params ver myAuthCIDs peerAuthCIDs
  where
    params = confParameters scConfig

----------------------------------------------------------------

isClient :: Connection -> Bool
isClient Connection{..} = role == Client

isServer :: Connection -> Bool
isServer Connection{..} = role == Server

----------------------------------------------------------------

newtype Input = InpStream Stream deriving Show
data   Crypto = InpHandshake EncryptionLevel ByteString deriving Show

data Output = OutControl   EncryptionLevel [Frame]
            | OutHandshake [(EncryptionLevel,ByteString)]
            | OutRetrans   PlainPacket
            deriving Show

type InputQ  = TQueue Input
type CryptoQ = TQueue Crypto
type OutputQ = TQueue Output
type MigrationQ = TQueue CryptPacket
