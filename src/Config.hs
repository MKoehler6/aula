{-# LANGUAGE ConstraintKinds    #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TemplateHaskell    #-}

{-# OPTIONS_GHC -Werror -Wall -fno-warn-orphans #-}

module Config
    ( Config(Config)
    , ListenerConfig(..)
    , SmtpConfig(SmtpConfig)
    , CleanUpConfig(..)
    , CleanUpRule(..)

    , GetConfig(..), MonadReaderConfig
    , WarnMissing(DontWarnMissing, WarnMissing, CrashMissing)
    , PersistenceImpl(..)

    , aulaRoot
    , aulaTimeLocale
    , avatarPath
    , cfgCsrfSecret
    , checkAvatarPathExists
    , checkAvatarPathExistsAndIsEmpty
    , checkStaticHtmlPathExists
    , cleanUp
    , cleanUpDirectory
    , cleanUpInterval
    , cleanUpKeepnum
    , cleanUpPrefix
    , cleanUpRules
    , dbPath
    , defaultConfig
    , defaultRecipient
    , delegateLikes
    , devMode
    , exposedUrl
    , getSamplesPath
    , htmlStatic
    , listener
    , listenerInterface
    , listenerPort
    , logging
    , logmotd
    , monitoring
    , persist
    , persistenceImpl
    , readConfig, configFilePath
    , releaseVersion
    , senderEmail
    , senderName
    , sendmailArgs
    , sendmailPath
    , setCurrentDirectoryToAulaRoot
    , smtp
    , snapshotInterval
    , timeoutCheckInterval
    , unsafeTimestampToLocalTime
    )
where

import Control.Exception (throwIO, ErrorCall(ErrorCall))
import Control.Lens
import Control.Monad (unless)
import Control.Monad.Reader (MonadReader)
import Data.Functor.Infix ((<$$>))
import Data.List (isSuffixOf)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.String.Conversions (SBS, cs)
import Data.Time
import Data.Version (showVersion)
import Data.Yaml
import GHC.Generics
import System.Directory
import System.Environment
import System.FilePath ((</>))
import Text.Show.Pretty (ppShow)
import Thentos.CookieSession.CSRF (GetCsrfSecret(..), CsrfSecret(..))

import qualified System.IO.Unsafe
import qualified Data.Text as ST

import Logger
import Types hiding (logLevel)


import qualified Paths_aula as Paths
-- (if you are running ghci and Paths_aula is not available, try `-idist/build/autogen`.)


-- | FIXME: move this instance upstream and remove -fno-warn-orphans for this module.
instance ToJSON CsrfSecret where
  toJSON (CsrfSecret s) = String $ cs s

-- | FIXME: move this instance upstream and remove -fno-warn-orphans for this module.
instance FromJSON CsrfSecret where
  parseJSON o = CsrfSecret . (cs :: String -> SBS) <$> parseJSON o

data PersistenceImpl = AcidStateInMem | AcidStateOnDisk
  deriving (Eq, Ord, Show, Generic, ToJSON, FromJSON, Enum, Bounded)

data SmtpConfig = SmtpConfig
    { _senderName       :: String
    , _senderEmail      :: String
    , _defaultRecipient :: String  -- (will receive a test email on start, but also for e.g. for use in demo data.)
    , _sendmailPath     :: String
    , _sendmailArgs     :: [String]
   -- ^ Not using 'ST' here since Network.Mail.Mime wants 'String' anyway.
    }
  deriving (Show, Generic, ToJSON, FromJSON)

makeLenses ''SmtpConfig

data PersistConfig = PersistConfig
    { _dbPath           :: String
    , _persistenceImpl  :: PersistenceImpl
    , _snapshotInterval :: Timespan
    }
  deriving (Show, Generic, ToJSON, FromJSON)

makeLenses ''PersistConfig

data ListenerConfig = ListenerConfig
    { _listenerInterface :: String
    , _listenerPort      :: Int
    }
  deriving (Show, Generic, ToJSON, FromJSON)

makeLenses ''ListenerConfig

data CleanUpRule = CleanUpRule
    { _cleanUpDirectory :: FilePath
    , _cleanUpPrefix    :: FilePath
    , _cleanUpKeepnum   :: Int
    }
  deriving (Show, Generic, ToJSON, FromJSON)

makeLenses ''CleanUpRule

data CleanUpConfig = CleanUpConfig
    { _cleanUpInterval :: Timespan
    , _cleanUpRules    :: [CleanUpRule]
    }

  deriving (Show, Generic, ToJSON, FromJSON)

makeLenses ''CleanUpConfig

data Config = Config
    { _exposedUrl           :: String  -- e.g. https://aula-stage.liqd.net
    , _listener             :: ListenerConfig
    , _monitoring           :: Maybe ListenerConfig
    , _htmlStatic           :: FilePath
    , _avatarPath           :: FilePath  -- avatars are stored in this directory:
                                         -- FIXME: i think this is not working.  run `git grep
                                         -- \"/avatars\"`, and you will find a few places where
                                         -- Config should be consulted, but a string literal is used
                                         -- instead!
    , _cfgCsrfSecret        :: CsrfSecret
    , _logging              :: LogConfig
    , _persist              :: PersistConfig
    , _smtp                 :: SmtpConfig
    , _delegateLikes        :: Bool
    , _timeoutCheckInterval :: Timespan
    , _cleanUp              :: CleanUpConfig
    -- ^ Topics which needs to change phase due to a timeout will
    -- be checked at this interval.
    -- * once per day would be the minmum
    -- * 4 times a day (every 6 hours) would ensures that
    --   all the topics are ready at least at 6am.
    , _devMode              :: Bool
    }
  deriving (Show, Generic, ToJSON, FromJSON)  -- FIXME: make nicer JSON field names.

makeLenses ''Config

class GetConfig r where
    getConfig :: Getter r Config

    viewConfig :: MonadReader r m => m Config
    viewConfig = view getConfig

type MonadReaderConfig r m = (MonadReader r m, GetConfig r)

instance GetConfig Config where
    getConfig = id

instance GetCsrfSecret Config where
    csrfSecret = pre cfgCsrfSecret

defaultSmtpConfig :: SmtpConfig
defaultSmtpConfig = SmtpConfig
    { _senderName       = "Aula Notifications"
    , _senderEmail      = "aula@example.com"
    , _defaultRecipient = "postmaster@localhost"
    , _sendmailPath     = "/usr/sbin/sendmail"
    , _sendmailArgs     = ["-t"]
    }

defaultPersistConfig :: PersistConfig
defaultPersistConfig = PersistConfig
    { _dbPath           = "./state/AulaData"
    , _persistenceImpl  = AcidStateInMem
    , _snapshotInterval = TimespanMins 47
    }

defaultLogConfig :: LogConfig
defaultLogConfig = LogConfig
    { _logCfgLevel  = DEBUG
    , _logCfgPath   = "./aula.log"
    , _eventLogPath = "./aulaEventLog.json"
    }

defaulCleanUpConfig :: CleanUpConfig
defaulCleanUpConfig = CleanUpConfig
    { _cleanUpInterval = TimespanMins 45
    , _cleanUpRules    =
        [ CleanUpRule "./state/AulaData/Archive" "events" 0
        , CleanUpRule "./state/AulaData/Archive" "checkpoints" 10
        ]
    }

defaultConfig :: Config
defaultConfig = Config
    { _exposedUrl           = "http://localhost:8080"
    , _listener             = ListenerConfig "127.0.0.1" 8080
    , _monitoring           = Just (ListenerConfig "127.0.0.1" 8888)
    , _htmlStatic           = "./static"
    , _avatarPath           = "./avatars"
    , _cfgCsrfSecret        = CsrfSecret "please-replace-this-with-random-secret"
    , _logging              = defaultLogConfig
    , _persist              = defaultPersistConfig
    , _smtp                 = defaultSmtpConfig
    , _delegateLikes        = True
    , _timeoutCheckInterval = TimespanHours 6
    , _cleanUp              = defaulCleanUpConfig
    , _devMode              = False
    }


sanitize :: Config -> Config
sanitize = exposedUrl %~ (\u -> if "/" `isSuffixOf` u then init u else u)


data WarnMissing = DontWarnMissing | WarnMissing | CrashMissing
  deriving (Eq, Show)

-- | In case of @WarnMissing :: WarnMissing@, log the warning to stderr.  (We don't have logging
-- configured yet.)
readConfig :: WarnMissing -> IO Config
readConfig warnMissing = sanitize <$> (configFilePath >>= maybe (errr msgAulaPathNotSet >> dflt) decodeFileDflt)
  where
    dflt :: IO Config
    dflt = pure defaultConfig

    decodeFileDflt :: FilePath -> IO Config
    decodeFileDflt fp = decodeFileEither fp >>= either (\emsg -> errr (msgParseError emsg) >> dflt) pure

    msgAulaPathNotSet :: [String]
    msgAulaPathNotSet =
        [ "no config file found: $AULA_ROOT_PATH not set."
        , "to fix this, write the following lines to $AULA_ROOT_PATH/aula.yaml:"
        ]

    msgParseError :: Show a => a -> [String]
    msgParseError emsg =
        [ "could not read config file:"
        , show emsg
        , "to fix this, write the following lines to $AULA_ROOT_PATH/aula.yaml:"
        ]

    errr :: [String] -> IO ()
    errr msgH = case warnMissing of
        DontWarnMissing -> pure ()
        WarnMissing     -> unSendLogMsg stderrLog . LogEntry ERROR $ cs msgs
        CrashMissing    -> throwIO . ErrorCall $ msgs
      where
        msgs = unlines $ [""] <> msgH <> ["", cs $ encode defaultConfig]

configFilePath :: IO (Maybe FilePath)
configFilePath = (</> "aula.yaml") <$$> aulaRoot

aulaRoot :: IO (Maybe FilePath)
aulaRoot = lookup "AULA_ROOT_PATH" <$> getEnvironment

setCurrentDirectoryToAulaRoot :: IO ()
setCurrentDirectoryToAulaRoot = aulaRoot >>= maybe (pure ()) setCurrentDirectory

getSamplesPath :: IO FilePath
getSamplesPath = fromMaybe (error msg) . lookup var <$> getEnvironment
  where
    var = "AULA_SAMPLES"
    msg = "please set $" <> var <> " to a path (will be created if n/a)"


-- * release version

releaseVersion :: String
releaseVersion = "[v" <> showVersion Paths.version <> "]"


-- * system time, time zones

-- | This works as long as the running system doesn't move from one time zone to the other.  It
-- would be nicer to make that an extra 'Action' class, but I argue that it's not worth the time to
-- do it (and to have to handle the slightly larger code base from now on).
unsafeTimestampToLocalTime :: Timestamp -> ZonedTime
unsafeTimestampToLocalTime (Timestamp t) = System.IO.Unsafe.unsafePerformIO $ utcToLocalZonedTime t

aulaTimeLocale :: TimeLocale
aulaTimeLocale = defaultTimeLocale
  { knownTimeZones = knownTimeZones defaultTimeLocale
                  <> [TimeZone (1 * 60) False "CET", TimeZone (2 * 60) True "CEST"] }

checkAvatarPathExists :: Config -> IO ()
checkAvatarPathExists cfg = checkPathExists (cfg ^. avatarPath)

checkAvatarPathExistsAndIsEmpty :: Config -> IO ()
checkAvatarPathExistsAndIsEmpty cfg =
    checkPathExistsAndIsEmpty (cfg ^. avatarPath)

checkStaticHtmlPathExists :: Config -> IO ()
checkStaticHtmlPathExists cfg =
    checkPathExists (cfg ^. htmlStatic)

checkPathExists :: FilePath -> IO ()
checkPathExists path = do
    exists <- doesDirectoryExist path
    unless exists . throwIO . ErrorCall $
        show path <> " does not exist or is not a directory."

checkPathExistsAndIsEmpty :: FilePath -> IO ()
checkPathExistsAndIsEmpty path = do
    checkPathExists path
    isempty <- null <$> getDirectoryContentsNoDots path
    unless isempty . throwIO . ErrorCall $
        show path <> " does not exist, is not a directory, or is not empty."


-- * motd

-- | Log the message (motto) of the day (like /etc/motd).
logmotd :: Config -> FilePath -> IO ()
logmotd cfg wd = do
    name <- getProgName
    unSendLogMsg (aulaLog (cfg ^. logging)) . LogEntry INFO . ST.unlines $
        [ "starting " <> cs name
        , ""
        , "\nrelease:"
        , cs Config.releaseVersion
        , "\nroot path:"
        , cs wd
        , "\nsetup:", cs $ ppShow cfg
        , ""
        ]
