{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

{-# OPTIONS_GHC -Wall -Werror #-}

-- | The 'Action.Implementation' module contains a monad stack implmententation of the 'Action'
-- interface.
module Action.Implementation
    ( Action
    , mkRunAction
    , readEventLog
    )
where

import System.IO.Unsafe

import Codec.Picture
import Control.Lens
import Control.Monad.Except (MonadError, throwError)
import Control.Monad.IO.Class
import Control.Monad.RWS.Lazy
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, withExceptT)
import Data.Elocrypt (mkPassword)
import Data.Maybe (fromMaybe)
import Data.String.Conversions (cs)
import Data.Time.Clock (getCurrentTime)
import Prelude
import Servant
import Servant.Missing
import Test.QuickCheck  -- FIXME: remove
import Thentos.Action (freshSessionToken)
import Thentos.Prelude (DCLabel, MonadLIO(..), MonadRandom(..), evalLIO, LIOState(..), dcBottom)

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy.Char8 as LBS (lines)
import qualified Data.ByteString.Lazy as LBS

import Action
import Config
import Daemon (eventLogPath)
import Logger.EventLog
import Persistent
import Persistent.Api
import Types


-- * concrete monad type

-- | The actions a user can perform.
newtype Action a = MkAction { unAction :: ExceptT ActionExcept (RWST ActionEnv () UserState IO) a }
    deriving ( Functor
             , Applicative
             , Monad
             , MonadError ActionExcept
             , MonadReader ActionEnv
             , MonadState UserState
             )

actionIO :: IO a -> Action a
actionIO = MkAction . liftIO

instance GenArbitrary Action where  -- FIXME: remove
    genGen = actionIO . generate

instance HasSendMail ActionExcept ActionEnv Action where
    sendMailToAddress addr msg = MkAction $ do
        logger <- view envLogger
        sendMailToAddressIO logger addr msg

instance ActionLog Action where
    log msg = actionIO =<< views envLogger ($ msg)

-- | FIXME: test this (particularly strictness and exceptions)
instance ActionPersist Action where
    queryDb = actionIO =<< view (envRunPersist . rpQuery)

    update ev =
        either (throwError . ActionPersistExcept) pure
            =<< actionIO =<< views (envRunPersist . rpUpdate) ($ ev)

instance MonadLIO DCLabel Action where
    liftLIO = actionIO . (`evalLIO` LIOState dcBottom dcBottom)

instance MonadRandom Action where
    getRandomBytes = actionIO . getRandomBytes

instance ActionRandomPassword Action where
    mkRandomPassword = actionIO $ UserPassInitial . cs . unwords <$> mkPassword `mapM` [4,3,5]

instance ActionCurrentTimestamp Action where
    getCurrentTimestamp = actionIO $ Timestamp <$> getCurrentTime

instance ActionUserHandler Action where
    login uid = do
        usUserId .= Just uid
        sessionToken <- freshSessionToken
        usSessionToken .= Just sessionToken

    addMessage msg = usMessages %= (msg:)

    flushMessages = do
        msgs <- userState usMessages
        usMessages .= []
        pure $ reverse msgs

    userState = use

    logout = put userLoggedOut >> addMessage "Danke fürs Mitmachen!"

instance ReadTempFile Action where
    readTempFile = actionIO . LBS.readFile

instance CleanupTempFiles Action where
    cleanupTempFiles = actionIO . releaseFormTempFiles

instance ActionAvatar Action where
    readImageFile = actionIO . readImage
    savePngImageFile p = actionIO . savePngImage p

-- | Creates a natural transformation from Action to the servant handler monad.
-- See Frontend.runFrontend for the persistency of @UserState@.
mkRunAction :: ActionEnv -> Action :~> ExceptT ServantErr IO
mkRunAction env = Nat run
  where
    run = withExceptT runActionExcept . ExceptT . fmap (view _1) . runRWSTflip env userLoggedOut
        . runExceptT . unAction . (checkCurrentUser >>)
    runRWSTflip r s comp = runRWST comp r s

    checkCurrentUser = do
        isValid <- userState $ to validUserState
        unless isValid $ do
            logout
            throwError500 "Invalid internal user session state"

runActionExcept :: ActionExcept -> ServantErr
runActionExcept (ActionExcept e) = e
runActionExcept (ActionPersistExcept pe) = runPersistExcept pe
runActionExcept (ActionSendMailExcept e) = error500 # show e


-- * moderator's event log

{-# NOINLINE readEventLog #-}
readEventLog :: ActionM m => m EventLog  -- TODO do not use 'unsafePerformIO' (introduce type
                                         -- ActionEventLogM or something; move this entire section
                                         -- back to Action, donno)
readEventLog = do
    cfg <- viewConfig
    rows :: [EventLogItemCold]
         <- fmap adecode . LBS.lines <$> (pure . unsafePerformIO $ LBS.readFile eventLogPath)
    EventLog (cs $ cfg ^. exposedUrl) <$> (warmUp `mapM` rows)
  where
    adecode = fromMaybe (error "readEventLog: inconsistent data on disk.") . Aeson.decode


class WarmUp m cold warm where
    warmUp :: cold -> m warm

instance ActionM m => WarmUp m EventLogItemCold EventLogItemWarm where
    warmUp (EventLogItem' ispace tstamp usr val) =
        EventLogItem' ispace tstamp <$> warmUp' usr <*> warmUp val

instance ActionM m => WarmUp m EventLogItemValueCold EventLogItemValueWarm where
    warmUp = \case
        EventLogUserCreates c
            -> EventLogUserCreates <$> warmUp c
        EventLogUserEdits c
            -> EventLogUserCreates <$> warmUp c
        EventLogUserMarksIdeaFeasible i t
            -> do i' <- warmUp' i; pure $ EventLogUserMarksIdeaFeasible i' t
        EventLogUserVotesOnIdea i v
            -> do i' <- warmUp' i; pure $ EventLogUserVotesOnIdea i' v
        EventLogUserVotesOnComment i c mc ud
            -> do i' <- warmUp' i; c' <- warmUp' c; mc' <- mapM warmUp' mc;
                  pure $ EventLogUserVotesOnComment i' c' mc' ud
        EventLogUserDelegates s u
            -> EventLogUserDelegates s <$> warmUp' u
        EventLogTopicNewPhase t p1 p2
            -> do t' <- warmUp' t; pure $ EventLogTopicNewPhase t' p1 p2
        EventLogIdeaNewTopic i mt1 mt2
            -> do i' <- warmUp' i; mt1' <- mapM warmUp' mt1; mt2' <- mapM warmUp' mt2;
                  pure $ EventLogIdeaNewTopic i' mt1' mt2'
        EventLogIdeaReachesQuorum i
            -> EventLogIdeaReachesQuorum <$> warmUp' i


instance ActionM m => WarmUp m ContentCold ContentWarm where
    warmUp = \case
        Left3   t -> Left3   <$> warmUp' t
        Middle3 t -> Middle3 <$> warmUp' t
        Right3  t -> Right3  <$> warmUp' t

-- | for internal use only.
class WarmUp' m a where
    warmUp' :: KeyOf a -> m a

instance ActionM m => WarmUp' m User where
    warmUp' k = equery (maybe404 =<< findUser k)

instance ActionM m => WarmUp' m Topic where
    warmUp' k = equery (maybe404 =<< findTopic k)

instance ActionM m => WarmUp' m Idea where
    warmUp' k = equery (maybe404 =<< findIdea k)

instance ActionM m => WarmUp' m Comment where
    warmUp' k = equery (maybe404 =<< findComment k)
