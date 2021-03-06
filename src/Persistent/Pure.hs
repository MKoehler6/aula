{-# LANGUAGE ConstraintKinds             #-}
{-# LANGUAGE DeriveDataTypeable          #-}
{-# LANGUAGE DeriveGeneric               #-}
{-# LANGUAGE FlexibleContexts            #-}
{-# LANGUAGE GADTs                       #-}
{-# LANGUAGE GeneralizedNewtypeDeriving  #-}
{-# LANGUAGE ImpredicativeTypes          #-}
{-# LANGUAGE LambdaCase                  #-}
{-# LANGUAGE OverloadedStrings           #-}
{-# LANGUAGE ScopedTypeVariables         #-}
{-# LANGUAGE TemplateHaskell             #-}
{-# LANGUAGE TupleSections               #-}
{-# LANGUAGE TypeOperators               #-}
{-# LANGUAGE ViewPatterns                #-}

{-# OPTIONS_GHC -Wall -Werror -fno-warn-orphans #-}

-- | This module exports acid-state transactions.  It introduces a state type 'AulaData' and 'Query'
-- and 'Update' operations on that state.  (To be more specific, a few new types for queries and
-- updates are defined that specific to 'AulaData' and introduce exceptions.)
--
-- Serialization happens outside of this module.
--
-- FIXME: get some structure into the export list.
-- FIXME: consider removing Purescript.Idiom and doing everything here.
module Persistent.Pure
    ( AulaData
    , AMap
    , AulaLens
    , AulaGetter
    , AulaSetter
    , emptyAulaData

    , EnvWith(..), EnvWithProto, envUser, envNow, envWith
    , AEvent, Query, EQuery, MQuery, AUpdate(AUpdate), AddDb
    , runAUpdate
    , aUpdateEvent

    , PersistExcept(..)
    , _PersistError500, _PersistError404, _PersistErrorNotImplemented
    , runPersistExcept
    , HasAUpdate
    , liftAQuery
    , dbSnapshot

    , addDb
    , addDb'
    , findIn
    , findInBy
    , findInById
    , findAllIn
    , findAllInBy
    , maybe404

    , getSpaces
    , getSpacesForScope
    , getSpacesForRoles
    , getIdeas
    , getWildIdeas
    , getIdeasWithTopic
    , addIdeaSpaceIfNotExists
    , addIdea
    , withIdea
    , findIdea
    , findIdeaBy
    , findIdeasByTopicId
    , findIdeasByTopic
    , findIdeasByUserId
    , findIdeasBySpace
    , findWildIdeasBySpace
    , findComment
    , findComment'
    , addLikeToIdea
    , delikeIdea
    , addVoteToIdea
    , removeVoteFromIdea
    , addCommentToIdea
    , setCommentDesc
    , addReply
    , addCommentVote
    , findUser
    , findUserByLogin
    , findUsersByRole
    , findUsersByEmail
    , getActiveUsers
    , getAllUsers
    , getUsersInClass
    , getSchoolClasses
    , loginIsAvailable
    , genUserLoginCandidates
    , addUser
    , addFirstUser
    , mkMetaInfo
    , withUser
    , setUserDesc
    , setUserEmail
    , setUserPass
    , setUserLogin
    , checkClassNameIsAvailable
    , classNameIsAvailable
    , renameClass
    , filterClasses
    , destroyClassPure
    , destroyClass
    , addUserRole
    , remUserRole
    , resetUserPass
    , getTopics
    , setTopicPhase
    , addTopic
    , addTopicYieldLocs
    , editTopic
    , withTopic
    , IdeaChangedLocation, ideaChangedLocation
    , ideaChangedLocationIdea, ideaChangedLocationFrom, ideaChangedLocationTo
    , moveIdeasToLocation
    , findTopic
    , findTopic'
    , findTopicBy
    , findTopicsBySpace
    , dbElaborationDuration
    , dbVoteDuration
    , dbSchoolQuorum
    , dbClassQuorum
    , dbDurations
    , dbQuorums
    , dbFreeze
    , dbUserMap
    , dbSpaceSet
    , addDelegation
    , withdrawDelegation
    , delegationScopeForest
    , dscopeFull
    , delegationFull
    , allDelegationScopes
    , Persistent.Pure.delegates
    , Persistent.Pure.delegateInScope
    , Persistent.Pure.delegatees
    , Persistent.Pure.delegateesInScope
    , Persistent.Pure.votingPower
    , Persistent.Pure.findDelegationsByScope
    , findImplicitDelegationsByScope
    , addPasswordToken
    , checkValidPasswordToken
    , Persistent.Pure.removePasswordToken
    , addIdeaJuryResult
    , removeIdeaJuryResult
    , setCreatorStatement
    , addIdeaVoteResult
    , revokeWinnerStatus
    , editIdea
    , deleteIdea
    , deleteTopic
    , moveIdeaToLocation
    , moveIdeaToTopic
    , deleteComment
    , saveDurations
    , saveQuorums
    , dangerousResetAulaData
    , dangerousRenameAllLogins
    , termsOfUse
    , setTermsOfUse
    , wipeIdeasAndTopics

    , TraverseMetas
    , commentMetas
    , ideaMetas
    , aulaMetas
    , aulaUserLogins

    , renameInAulaData

    , fixComment
    , fixIdea
    , fixAulaData
    , fixAulaDataUpdate
    )
where

import Control.Lens
import Control.Monad.Except (MonadError, ExceptT(ExceptT), runExceptT)
import Control.Monad.Reader (MonadReader, runReader, asks)
import Control.Monad.State (MonadState, gets, put, modify)
import Control.Monad (foldM, unless, when, replicateM, forM, forM_, filterM)
import Data.Acid.Core
import Data.Acid.Memory.Pure (Event(UpdateEvent))
import Data.Acid (UpdateEvent, EventState, EventResult)
import Data.Data (Data)
import Data.Foldable (find, for_)
import Data.Functor
import Data.Functor.Infix ((<$$>))
import Data.List (nub)
import Data.Maybe
import Data.Map (Map)
import Data.SafeCopy (base, deriveSafeCopy)
import Data.Set (Set)
import Data.Set.Lens
import Data.String.Conversions (ST, cs, (<>))
import Data.Tree
import Data.Typeable (Typeable, typeRep)
import GHC.Generics (Generic)
import Servant
import Servant.Missing (ThrowError500(..))

import qualified Data.Acid as Acid
import qualified Data.Map  as Map
import qualified Data.Set  as Set
import qualified Data.Text as ST
import qualified Generics.SOP as SOP

import Types
import LifeCycle (freezePhase)
import Data.Delegation
import Data.PasswordTokens


-- * state type

data AulaData = AulaData
    { _dbSpaceSet            :: Set IdeaSpace
    -- ^ FIXME: Assuming SchoolSpace is always present, a 'Set SchoolClass' would be enough.
    , _dbIdeaMap             :: Ideas
    , _dbUserMap             :: Users
    , _dbTopicMap            :: Topics
    , _dbDelegations         :: Delegations
    , _dbResetPwdTokens      :: PasswordTokens
    , _dbTermsOfUse          :: Document
    , _dbSettings            :: Settings
    , _dbLastId              :: Integer
    }
  deriving (Eq, Show, Read, Typeable, Generic, Data)

instance SOP.Generic AulaData

makeLenses ''AulaData

type AulaLens a = Lens' AulaData a
type AulaGetter a = Getter AulaData a
type AulaSetter a = Setter' AulaData a
type AulaTraversal a = Traversal' AulaData a

noDeletedIdeas :: [Idea] -> [Idea]
noDeletedIdeas  = filter (not . view ideaDeleted)

noDeletedTopics :: [Topic] -> [Topic]
noDeletedTopics = filter (not . view topicDeleted)

dbSpaces :: AulaGetter [IdeaSpace]
dbSpaces = dbSpaceSet . to Set.elems

dbIdeas :: AulaGetter [Idea]
dbIdeas = dbIdeaMap . to Map.elems

dbUsers :: AulaGetter [User]
dbUsers = dbUserMap . to Map.elems

dbTopics :: AulaGetter [Topic]
dbTopics = dbTopicMap . to Map.elems . to noDeletedTopics

dbSnapshot :: AulaGetter AulaData
dbSnapshot = to id

emptyAulaData :: AulaData
emptyAulaData =
    AulaData
        nil
        nil
        nil
        nil
        emptyDelegations
        emptyPasswordTokens
        mempty
        defaultSettings
        0

type TraverseMetas a = forall b. Traversal' (MetaInfo b) a

commentMetas :: TraverseMetas a -> Traversal' Comment a
commentMetas t f (Comment m text votes replies deleted) =
    Comment <$> t f m                               -- A MetaInfo
            <*> pure text                           -- No MetaInfo in commentText
            <*> (each . metaInfo . t) f votes       -- Only one MetaInfo per CommentVote
            <*> (each . commentMetas t) f replies   -- See commentMetas
            <*> pure deleted                        -- No MetaInfo in commentDeleted

ideaMetas :: TraverseMetas a -> Traversal' Idea a
ideaMetas t f (Idea m title desc cat loc comments likes votes juryRes voteRes deleted) =
    Idea <$> t f m                              -- A MetaInfo
         <*> pure title                         -- No MetaInfo in ideaTitle
         <*> pure desc                          -- No MetaInfo in ideaDesc
         <*> pure cat                           -- No MetaInfo id ideaCategory
         <*> pure loc                           -- No MetaInfo id ideaLoc
         <*> (each . commentMetas t) f comments -- See commentMetas
         <*> (each . metaInfo . t) f likes      -- Only one MetaInfo per IdeaLike
         <*> (each . metaInfo . t) f votes      -- Only one MetaInfo per IdeaVote
         <*> (each . metaInfo . t) f juryRes    -- Only one MetaInfo per IdeaJuryResult
         <*> (each . metaInfo . t) f voteRes    -- Only one MetaInfo per IdeaVoteResult
         <*> pure deleted

-- This is using pattern matching on AulaData to force us to adapt this function when extending it.
aulaMetas :: TraverseMetas a -> AulaTraversal a
aulaMetas t f (AulaData sp is us ts ds pt tou st li) =
    AulaData <$> pure sp                    -- No MetaInfo in dbSpaceSet
             <*> (each . ideaMetas  t) f is -- See ideaMetas
             <*> (each . metaInfo . t) f us -- Only one MetaInfo per User
             <*> (each . metaInfo . t) f ts -- Only one MetaInfo per Topic
             <*> pure ds                    -- No MetaInfo in dbDelegations
             <*> pure pt                    -- No MetaInfo in dbPasswordTokens
             <*> pure tou                   -- No MetaInfo in dbTermsOfUse
             <*> pure st                    -- No MetaInfo in dbSettings
             <*> pure li                    -- No MetaInfo in dbListId

aulaUserLogins :: AulaSetter UserLogin
aulaUserLogins = mergeSetters (dbUserMap . each . userLogin) (aulaMetas metaCreatedByLogin)
  where
    -- Only valid when the targets of the two setters are non overlapping
    mergeSetters :: ASetter s t a b -> ASetter t u a b -> Setter s u a b
    mergeSetters l0 l1 = sets $ \f -> over l1 f . over l0 f


-- * transactions

type AEvent = Event AulaData

-- | 'Query' for 'AulaData'.
type Query a = forall m. MonadReader AulaData m => m a

-- | Same as 'Query' but can throw 'PersistExcept'.
type EQuery a = forall m. (MonadError PersistExcept m, MonadReader AulaData m) => m a

-- | This shortcut for 'EQuery' that throws the appropriate 'PersistExcept' on 'Nothing'.
type MQuery a = Query (Maybe a)

-- | 'Update' for 'AulaData'.  Can throw 'PersistExcept'.
newtype AUpdate a = AUpdate { _unAUpdate :: ExceptT PersistExcept (Acid.Update AulaData) a }
  deriving ( Functor
           , Applicative
           , Monad
           , MonadError PersistExcept
           , MonadState AulaData
           )

maybe404 :: forall m a. (MonadError PersistExcept m, Typeable a) => Maybe a -> m a
maybe404 = maybe (throwError . PersistError404 . show . typeRep $ (Proxy :: Proxy a)) pure

runAUpdate :: AUpdate a -> Acid.Update AulaData (Either PersistExcept a)
runAUpdate = runExceptT . _unAUpdate

aUpdateEvent :: (UpdateEvent ev, EventState ev ~ AulaData, EventResult ev ~ Either PersistExcept a)
             => (ev -> AUpdate a) -> AEvent
aUpdateEvent f = UpdateEvent $ runAUpdate . f

type HasAUpdate ev a = (UpdateEvent ev, MethodState ev ~ AulaData, MethodResult ev ~ Either PersistExcept a)

liftAQuery :: Query a -> AUpdate a
liftAQuery m = gets (runReader m)

-- * exceptions

-- | FIXME: this will have constructors dedicated for specific errors, and 'ServantErr' will only be
-- introduced later.
data PersistExcept
    = PersistError500 { persistErrorMessage :: String }
        -- FIXME: rename to PersistExceptInternal; drop ThrowError500 instance for something prismatic just for PersistExcept
    | PersistError404 { persistErrorMessage :: String }
        -- FIXME: rename to PersistExceptNotFound
    | PersistErrorNotImplemented { persistErrorMessage :: String }
    | UserLoginInUse UserLogin
    | ClassNameInUse ClassName
    deriving (Eq, Show)

makePrisms ''PersistExcept

instance LogMessage PersistExcept where
    logLevel = \case
        PersistError404 _ -> DEBUG
        _                 -> ERROR
    logMessage = \case
        PersistError500 msg            -> cs $ "500 " <> msg
        PersistError404 msg            -> cs $ "404 " <> msg
        PersistErrorNotImplemented msg -> cs $ "Not implemented: " <> msg
        UserLoginInUse ul              -> cs $ "User login in use: " <> ul ^. unUserLogin
        ClassNameInUse cl              -> cs $ "Class name in use: " <> cl ^. unClassName

instance ThrowError500 PersistExcept where
    error500 = _PersistError500

deriveSafeCopy 0 'base ''PersistExcept

runPersistExcept :: PersistExcept -> ServantErr
runPersistExcept (PersistError500 msg)            = err500 { errBody = cs msg }
runPersistExcept (PersistError404 msg)            = err404 { errBody = cs msg }
runPersistExcept (PersistErrorNotImplemented msg) = err500 { errBody = cs msg }
runPersistExcept (UserLoginInUse li) =
    err403 { errBody = "user login in use: " <> cs (show li) }
runPersistExcept (ClassNameInUse cl) =
    err403 { errBody = "class name in use: " <> cs (show cl) }


-- * state interface

-- | The argument is a consistency check that will throw an error if it fails.
--
-- This can be equipped with a switch for performance, but if at all possible it would be nice to
-- run the checks even in production.
assertAulaDataM :: Query () -> AUpdate ()
assertAulaDataM = liftAQuery

{-
    This type carries the information needed to add (or update) something to the DB,
    namely the current user, the current time and the last parameter depends on the
    application.

    It can be thought of as the type @Meta a@ but with only the information we cannot
    compute from the current state or input data. Also unlike @Meta@ which is embedded
    in all our types (@Idea@, @Topic@), @EnvWith@ is surrunding the data.

    See also @EnvWithProto@.
-}
data EnvWith a = EnvWith
    { _envUser :: User
    , _envNow  :: Timestamp
    , _envWith :: a
    }

makeLenses ''EnvWith

deriveSafeCopy 0 'base ''EnvWith

{-
    The type @EnvWithProto a@ is a synonym for @EnvWith (Proto a)@.
    Since @Proto a@ collects all the (non-meta) information about the creation an @a@ record,
    @EnvWithProto a@ contains all the information to create an @a@.
-}
type EnvWithProto a = EnvWith (Proto a)

{-
    Functions of type @AddDb a@ are commonly partial applications of @addDb@.
    Thus such a function still lacks the @EnvWithProto a@, namely some meta-data and the @Proto a@,
    combinators such as @addWithUser@ and @addWithCurrentUser@ deal with building and providing the
    meta-data. On subtelty introduced by AcidState is that instead of using directly the functions
    of type @AddDb@ one must use their event counter part.
    For instance @addIdea@ has type @AddDb Idea@, namely @EnvWithProto Idea -> AUpdate Idea@
    while @AddIdea@ has type @EnvWithProto Idea -> AddIdea@.
    Here are some examples:
    * @addWithCurrentUser AddIdea someUser@
    * @addWithUser AddIdea someUser someProtoIdea@
    * @addWithUser (AddLikeToIdea someIdeaId) someUser ()@
-}
type AddDb a = EnvWithProto a -> AUpdate a

addDb' :: forall a. (HasMetaInfo a, FromProto a) =>
          (User -> AUpdate (KeyOf a)) -> AulaTraversal (AMap a) -> AddDb a
addDb' mkKey l (EnvWith cUser now pa) = do
    assertAulaDataM $ do
        len <- asks (lengthOf l)
        when (len /= 1) $ do
            fail $ "Persistent.Api.addDb expects the location (lens, traversal) "
                <> "to target exactly 1 field not " <> show len
    aid <- mkKey cUser
    let a = fromProto pa $ mkMetaInfo cUser now aid
    l . at (aid ^. idOfKey (Proxy :: Proxy a)) <?= a

-- | @addDb l (EnvWith u now p)@ adds a record to the DB.
-- The record is added on the behalf of the user @u@.
-- The record is computed from the prototype @p@, the current time @now@ and the given user @u@.
-- The record is added at the location pointed by the traversal @l@.
--
-- It is expected that @l@ points to exactly one target (checked by 'assertAulaDataM').
--
-- We could make the type of @l@ be @AulaLens (AMap a)@ which would enforce the constraint
-- above at the expense of pushing the burden towards cases where the traversal is only a
-- lens when some additional assumptions are met (see addReply for instance).
--
-- It could make sense for the traversal to point to more than one target for instance
-- to index the record at different locations. For instance we could keep an additional
-- global map of the comments, votes, likes and still call @addDb@ only once.
addDb :: (KeyOf a ~ AUID a, HasMetaInfo a, FromProto a) => AulaTraversal (AMap a) -> AddDb a
addDb = addDb' $ const nextId


addDbAppValue :: (KeyOf a ~ AUID a, HasMetaInfo a, FromProto a, Applicative ap)
    => AulaTraversal (ap a) -> AddDb a
addDbAppValue l (EnvWith cUser now pa) = do
    a <- fromProto pa <$> nextMetaInfo cUser now
    l .= pure a
    pure a

findIn :: AulaGetter [a] -> (a -> Bool) -> MQuery a
findIn l = views l . find

findAllIn :: AulaGetter [a] -> (a -> Bool) -> Query [a]
findAllIn l = views l . filter

findInBy :: Eq b => AulaGetter [a] -> Fold a b -> b -> MQuery a
findInBy l f b = findIn l (\x -> x ^? f == Just b)

findAllInBy :: Eq b => AulaGetter [a] -> Fold a b -> b -> Query [a]
findAllInBy l f b = findAllIn l (\x -> x ^? f == Just b)

findInById :: HasMetaInfo a => AulaGetter (AMap a) -> IdOf a -> MQuery a
findInById l i = view (l . at i)

getSpaces :: Query [IdeaSpace]
getSpaces = view dbSpaces

getIdeas :: Query [Idea]
getIdeas = filter (not . view ideaDeleted) <$> getIdeasIncludingDeleted

getIdeasIncludingDeleted :: Query [Idea]
getIdeasIncludingDeleted = view dbIdeas

getWildIdeas :: Query [Idea]
getWildIdeas = filter (isWild . view ideaLocation) <$> getIdeas

getIdeasWithTopic :: Query [Idea]
getIdeasWithTopic = filter (not . isWild . view ideaLocation) <$> getIdeas

-- | If idea space already exists, do nothing.  Otherwise, create it.
addIdeaSpaceIfNotExists :: IdeaSpace -> AUpdate ()
addIdeaSpaceIfNotExists ispace = do
    exists <- (ispace `elem`) <$> liftAQuery getSpaces
    unless exists $ dbSpaceSet %= Set.insert ispace

addIdea :: AddDb Idea
addIdea = addDb dbIdeaMap

-- | Returns an idea, even if it is deleted.
findIdea :: AUID Idea -> MQuery Idea
findIdea = findInById dbIdeaMap

findIdeaBy :: Eq a => Fold Idea a -> a -> MQuery Idea
findIdeaBy = fmap nonDeletedIdea <..> findInBy dbIdeas
  where
    nonDeletedIdea = (>>= (\i -> justIfP i (not . view ideaDeleted)))

findIdeasByUserId :: AUID User -> Query [Idea]
findIdeasByUserId uId = filter (not . view ideaDeleted) <$> findAllIn dbIdeas (\i -> i ^. createdBy == uId)

-- | FIXME deal with changedBy and changedAt
withRecord :: Ord (IdOf a) => AulaLens (AMap a) -> IdOf a -> AulaTraversal a
withRecord l ident = l . at ident . _Just

withIdea :: AUID Idea -> AulaTraversal Idea
withIdea = withRecord dbIdeaMap

withUser :: AUID User -> AulaTraversal User
withUser = withRecord dbUserMap

setUserDesc :: AUID User -> Document -> AUpdate ()
setUserDesc uid desc = withUser uid . userDesc .= desc

setUserEmail :: AUID User -> EmailAddress -> AUpdate ()
setUserEmail uid email = withUser uid . userEmail ?= email

resetUserPass :: AUID User -> InitialPassword -> AUpdate ()
resetUserPass uid userPass = withUser uid . userSettings . userSettingsPassword .= UserPassInitial userPass

setUserPass :: AUID User -> EncryptedPassword -> AUpdate ()
setUserPass uid pass =
    withUser uid . userSettings . userSettingsPassword .= UserPassEncrypted pass

setUserLogin :: AUID User -> UserLogin -> AUpdate ()
setUserLogin uid login = do
    checkLoginIsAvailable login
    user <- maybe404 =<< liftAQuery (findUser uid)
    aulaMetas metaCreatedByLogin %= \old -> if old == user ^. userLogin then login else old
    withUser uid . userLogin .= login

type RenameIn a = (ClassName -> ClassName) -> a -> a

renameInAulaData :: RenameIn AulaData
renameInAulaData f aulaData =
    aulaData
        & dbSpaceSet . setmapped . ideaSpaceSchoolClass . className %~ f
        & dbIdeaMap  . each %~ renameInIdea f
        & dbUserMap  . each . userRoleSet . setmapped . roleSchoolClass . _Just . className %~ f
        & dbTopicMap . each . topicIdeaSpace . ideaSpaceSchoolClass . className %~ f
        & dbDelegations %~ renameDelegations (renameInDScope f)

renameInCommentKey :: RenameIn CommentKey
renameInCommentKey f = ckIdeaLocation . ideaLocationSpace . ideaSpaceSchoolClass . className %~ f

renameInComment :: RenameIn Comment
renameInComment f comment = comment
    & commentMeta    . metaKey %~ renameInCommentKey f
    & commentVotes   . each . commentVoteMeta . metaKey . cvCommentKey %~ renameInCommentKey f
    & commentReplies . each %~ renameInComment f

renameInIdea :: RenameIn Idea
renameInIdea f idea = idea
    & ideaLocation . ideaLocationSpace . ideaSpaceSchoolClass . className %~ f
    & ideaComments . each %~ renameInComment f

renameInDScope :: RenameIn DScope
renameInDScope f = dScopeIdeaSpace . ideaSpaceSchoolClass . className %~ f

classNameIsAvailable :: ClassName -> Query Bool
classNameIsAvailable cl =
    asks (not . elemOf (dbSpaceSet . folded . ideaSpaceSchoolClass . className) cl)

checkClassNameIsAvailable :: ClassName -> AUpdate ()
checkClassNameIsAvailable cl = do
    isAvailable <- liftAQuery $ classNameIsAvailable cl
    unless isAvailable . throwError $ ClassNameInUse cl

renameClass :: SchoolClass -> ClassName -> AUpdate ()
renameClass (SchoolClass _ old) new
    | old == new = pure ()
    | otherwise  = do
        checkClassNameIsAvailable new
        modify . renameInAulaData $ \x -> if x == old then new else x

-- @filterInMapBy f p m@
-- In the map @m@, keep only the bindings for which all the targets of the fold @f@ satisfify
-- the predicate @p@.
filterInMapBy :: Fold a b -> (b -> Bool) -> Map k a -> Map k a
filterInMapBy selector predicate = Map.filter (allOf selector predicate)

-- @filterInSetBy f p s@
-- In the set @m@, keep only the elements for which all the targets of the fold @f@ satisfify
-- the predicate @p@.
filterInSetBy :: Fold a b -> (b -> Bool) -> Set a -> Set a
filterInSetBy selector predicate = Set.filter (allOf selector predicate)

filterClasses :: (SchoolClass -> Bool) -> AulaData -> AulaData
filterClasses p d = d
    & dbSpaceSet    %~ filterInSetBy ideaSpaceSchoolClass                                       p
    & dbIdeaMap     %~ filterInMapBy (ideaLocation . ideaLocationSpace . ideaSpaceSchoolClass)  p
    & dbTopicMap    %~ filterInMapBy (topicIdeaSpace . ideaSpaceSchoolClass)                    p
    & dbDelegations %~ filterDelegationsByScope (allOf (dScopeIdeaSpace . ideaSpaceSchoolClass) p)
    & dbUserMap . each . userRoleSet . setmapped . roleSchoolClass %~ filterRole
  where
    filterRole x | allOf _Just p x = x
                 | otherwise       = Nothing

destroyClassPure :: SchoolClass -> AulaData -> AulaData
destroyClassPure clss = filterClasses (/= clss)

destroyClass :: SchoolClass -> AUpdate ()
destroyClass = modify . destroyClassPure

addUserRole :: AUID User -> Role -> AUpdate ()
addUserRole uid role_ = withUser uid . userRoleSet %= Set.insert role_

remUserRole :: AUID User -> Role -> AUpdate ()
remUserRole uid role_ = withUser uid . userRoleSet %= Set.delete role_

-- | Update topic value.  Returns information about the ideas that have changed location.
editTopic :: AUID Topic -> EditTopicData -> AUpdate [IdeaChangedLocation]
editTopic topicId (EditTopicData title desc ideas) = do
    withTopic topicId %= (set topicTitle title . set topicDesc desc)
    previouslyInTopic :: [AUID Idea] <- view _Id <$$> liftAQuery (findIdeasByTopicId topicId)
    space <- view topicIdeaSpace <$> (maybe404 =<< liftAQuery (findTopic topicId))
    (<>) <$> moveIdeasToLocation previouslyInTopic (IdeaLocationSpace space)
         <*> moveIdeasToLocation ideas (IdeaLocationTopic space topicId)

withTopic :: AUID Topic -> AulaTraversal Topic
withTopic t = withRecord dbTopicMap t . filtered (not . _topicDeleted)

findUser :: AUID User -> MQuery User
findUser = findInById dbUserMap

getActiveUsers :: Query [User]
getActiveUsers = filter isActiveUser <$> view dbUsers

getAllUsers :: Query [User]
getAllUsers = view dbUsers

getUsersInClass :: SchoolClass -> Query [User]
getUsersInClass clss = filter userInClass <$> getActiveUsers
  where
    userInClass u = clss `elem` u ^.. userSchoolClasses

getSchoolClasses :: Query [SchoolClass]
getSchoolClasses = mapMaybe toClass <$> getSpaces
  where
    toClass (ClassSpace clss) = Just clss
    toClass SchoolSpace       = Nothing

getSpacesForRoles :: Set Role -> Query [IdeaSpace]
getSpacesForRoles roles = getSpacesForScope $ roles ^. rolesScope

getSpacesForScope :: RoleScope -> Query [IdeaSpace]
getSpacesForScope = \case
    ClassesScope classes -> let spaces = Set.map ClassSpace classes in
                            (SchoolSpace :) <$> findAllIn dbSpaces (`Set.member` spaces)
    SchoolScope          -> getSpaces

getTopics :: Query [Topic]
getTopics = view dbTopics

data IdeaChangedLocation = IdeaChangedLocation
    { _ideaChangedLocationIdea :: Idea
    , _ideaChangedLocationFrom :: Maybe (AUID Topic)
    , _ideaChangedLocationTo   :: Maybe (AUID Topic)
    }
  deriving (Eq, Ord, Show, Read)

ideaChangedLocation :: Idea -> Maybe (AUID Topic) -> Maybe (AUID Topic)
                    -> Maybe IdeaChangedLocation
ideaChangedLocation i f t = if f == t
    then Nothing
    else Just $ IdeaChangedLocation i f t

moveIdea :: AUID Idea -> (IdeaLocation -> IdeaLocation) -> AUpdate ()
moveIdea ideaId updateLoc = withIdea ideaId %= fixIdea . (ideaLocation %~ updateLoc)

moveIdeasToLocation :: [AUID Idea] -> IdeaLocation -> AUpdate [IdeaChangedLocation]
moveIdeasToLocation ideaIds newloc = do
    result <- forM ideaIds $ \ideaId -> do
        idea <- maybe404 =<< liftAQuery (findIdea ideaId)
        pure $ ideaChangedLocation idea
                  (idea ^? ideaLocation . ideaLocationTopicId)
                  (newloc ^? ideaLocationTopicId)
    for_ ideaIds $ \ideaId ->
        moveIdea ideaId (const newloc)
    return $ catMaybes result

moveIdeaToLocation :: MoveIdea -> IdeaLocation -> IdeaLocation
moveIdeaToLocation MoveIdeaToWild      s = IdeaLocationSpace (s ^. ideaLocationSpace)
moveIdeaToLocation (MoveIdeaToTopic t) s = IdeaLocationTopic (s ^. ideaLocationSpace) t

moveIdeaToTopic :: AUID Idea -> MoveIdea -> AUpdate ()
moveIdeaToTopic ideaId mTopicId = moveIdea ideaId (moveIdeaToLocation mTopicId)

setTopicPhase :: AUID Topic -> Phase -> AUpdate ()
setTopicPhase tid phase = withTopic tid . topicPhase .= phase

-- | Create a new topic from a topic proto and return it.  This calls 'addTopicYieldLocs', but
-- discards information about the ideas that have moved location.
addTopic :: Timestamp -> AddDb Topic
addTopic now pt = fst <$> addTopicYieldLocs now pt

-- | Like 'addTopic', but return extra information about the ideas that have been moved in or out of
-- the topic.
addTopicYieldLocs :: Timestamp -> EnvWithProto Topic -> AUpdate (Topic, [IdeaChangedLocation])
addTopicYieldLocs now pt = do
    t <- addDb dbTopicMap pt
    dbFrozen <- liftAQuery $ view dbFreeze
    when (dbFrozen == Frozen) . setTopicPhase (t ^. _Id) $ freezePhase now (t ^. topicPhase)
    -- (failure to match the following can only be caused by an inconsistent state)
    Just topic <- liftAQuery $ findTopic (t ^. _Id)
    -- FIXME a new topic should not be able to steal ideas from other topics of course the UI will
    -- hide this risk since only ideas without topics will be visible.
    -- Options:
    -- - Make it do nothing
    -- - Make it fail hard
    (topic,) <$> moveIdeasToLocation (pt ^. envWith . protoTopicIdeas) (topicIdeaLocation topic)


addDelegation :: AddDb Delegation
addDelegation env = do
    dbDelegations %= Data.Delegation.setDelegation delegatee scope delegate
    pure $ Delegation scope delegatee delegate
  where
    (Delegation scope delegatee delegate) = env ^. envWith

withdrawDelegation :: AUID User -> DScope -> AUID User -> AUpdate ()
withdrawDelegation delegatee dscope delegate =
    dbDelegations %= Data.Delegation.deleteDelegation delegatee dscope delegate

delegationScopeForest :: User -> Query [Tree DScopeFull]
delegationScopeForest user = do
    ideaSpaces <- DScopeIdeaSpaceFull <$$> getSpacesForRoles (user ^. userRoleSet)
    mapM (unfoldTreeM discover) ideaSpaces
  where
    discover :: DScopeFull -> Query (DScopeFull, [DScopeFull])
    discover s@(DScopeIdeaSpaceFull cspace) = do
        classTopics <- DScopeTopicFull <$$> findTopicsBySpace cspace
        pure (s, classTopics)

    discover s@DScopeTopicFull{} = do
        pure (s, [])

dscopeFull :: DScope -> EQuery DScopeFull
dscopeFull = \case
    DScopeIdeaSpace is -> pure $ DScopeIdeaSpaceFull is
    DScopeTopicId tid  -> DScopeTopicFull <$> (maybe404 =<< findTopic tid)

delegationFull :: Delegation -> EQuery DelegationFull
delegationFull (Delegation dscope f t) = DelegationFull dscope
    <$> (maybe404 =<< findUser f)
    <*> (maybe404 =<< findUser t)

allDelegationScopes :: Query [DScope]
allDelegationScopes = do
    topics <- getTopics
    spaces <- getSpaces
    pure $ (DScopeIdeaSpace <$> spaces)
            <> (DScopeTopicId . view _Id <$> topics)

-- | Returns all the delegates for a given delegatee with its scope
delegates :: AUID User -> EQuery [Delegation]
delegates delegatee =
    (\(scope,delegate) -> Delegation scope delegatee delegate)
    <$$> views dbDelegations (Data.Delegation.delegates delegatee)

delegateInScope :: AUID User -> DScope -> EQuery (Maybe Delegation)
delegateInScope delegatee scope =
    Delegation scope delegatee
    <$$> views dbDelegations (Data.Delegation.delegateInScope delegatee scope)

delegatees :: AUID User -> EQuery [Delegation]
delegatees delegate =
    concat <$>
    ((\(scope, delegatees') -> (\d -> Delegation scope d delegate) <$> Set.toList delegatees')
     <$$> views dbDelegations (Data.Delegation.delegatees delegate))

delegateesInScope :: AUID User -> DScope -> EQuery [Delegation]
delegateesInScope delegate scope =
    (\delegatee -> Delegation scope delegatee delegate)
    <$$> Set.toList
    <$> views dbDelegations (Data.Delegation.delegateesInScope delegate scope)

votingPower :: AUID User -> DScope -> EQuery [User]
votingPower uid scope = filter isActiveUser <$> do
    ancestors <- scopeAncestors scope
    catMaybes
        <$> (mapM findUser
             =<< views dbDelegations (Data.Delegation.votingPower uid ancestors))

scopeAncestors :: DScope -> EQuery [DScope]
scopeAncestors = \case
    s@DScopeIdeaSpace{}    -> pure [s]
    t@(DScopeTopicId tid)  -> do
        space <- _topicIdeaSpace <$> (maybe404 =<< findTopic tid)
        (t:) <$> scopeAncestors (DScopeIdeaSpace space)

findDelegationsByScope :: DScope -> Query (Map.Map (Delegate (AUID User)) [(DScope, Delegatee (AUID User))])
findDelegationsByScope scope = do
    delegs  <- views dbDelegations (Data.Delegation.findDelegationsByScope scope)
    delegs' <- sequence $ f <$> delegs
    pure . Map.fromList . catMaybes $ delegs'
  where
    f (d, s, ds) = do
        yes <- isActiveDelegate d
        if yes
            then do
                ds' <- filterM isActiveDelegatee ds
                pure $ Just (d, (s,) <$> ds')
            else pure Nothing

isActiveDelegate :: Delegate (AUID User) -> Query Bool
isActiveDelegate (Delegate u) = maybe False isActiveUser <$> findUser u

isActiveDelegatee :: Delegatee (AUID User) -> Query Bool
isActiveDelegatee (Delegatee u) = maybe False isActiveUser <$> findUser u

findImplicitDelegationsByScope :: DScope -> EQuery (Map.Map (Delegate (AUID User)) [(DScope, Delegatee (AUID User))])
findImplicitDelegationsByScope scope = do
    ancestors <- scopeAncestors scope

    let addScopeDeleg m scope' = do
            m' <- Persistent.Pure.findDelegationsByScope scope'
            pure $ Map.unionWith (++) m m'

    foldM addScopeDeleg Map.empty ancestors

addPasswordToken :: AUID User -> PasswordToken -> Timestamp -> Timespan -> AUpdate ()
addPasswordToken u token now later =
    dbResetPwdTokens %= Data.PasswordTokens.insertPasswordToken u token now later

checkValidPasswordToken :: AUID User -> PasswordToken -> Timestamp -> Query PasswordTokenState
checkValidPasswordToken u token now =
    views dbResetPwdTokens (Data.PasswordTokens.checkValid u token now)

removePasswordToken :: AUID User -> PasswordToken -> Timestamp -> AUpdate ()
removePasswordToken u token now =
    dbResetPwdTokens %= Data.PasswordTokens.removePasswordToken u token now

findUserByLogin :: UserLogin -> MQuery User
findUserByLogin = findInBy dbUsers userLogin

findUsersByRole :: Role -> Query [User]
findUsersByRole r = filter isActiveUser <$> findAllIn dbUsers (`hasRole` r)

findUsersByEmail :: EmailAddress -> Query [User]
findUsersByEmail e =
    findAllIn
        dbUsers
        (\u -> u ^? (userSettings . userSettingsEmail . _Just) == Just e)

-- FIXME: Unify deleted topic/idea/user handling
findTopic :: AUID Topic -> MQuery Topic
findTopic tid = (hideDeleted =<<) <$> findTopic' tid
  where
    hideDeleted t
        | _topicDeleted t = Nothing
        | otherwise       = Just t

-- | Finds a topic even if it is marked as deleted.
findTopic' :: AUID Topic -> MQuery Topic
findTopic' = findInById dbTopicMap

findTopicBy :: Eq a => Fold Topic a -> a -> MQuery Topic
findTopicBy = findInBy dbTopics

findTopicsBySpace :: IdeaSpace -> Query [Topic]
findTopicsBySpace = fmap noDeletedTopics . findAllInBy dbTopics topicIdeaSpace

findIdeasByTopicId :: AUID Topic -> Query [Idea]
findIdeasByTopicId tid = do
    mt <- findTopic tid
    case mt of
        Nothing -> pure []
        Just t  -> findIdeasByTopic t

findIdeasByTopic :: Topic -> Query [Idea]
findIdeasByTopic = fmap noDeletedIdeas . findAllInBy dbIdeas ideaLocation . topicIdeaLocation

findWildIdeasBySpace :: IdeaSpace -> Query [Idea]
findWildIdeasBySpace = fmap noDeletedIdeas . findAllInBy dbIdeas ideaLocation . IdeaLocationSpace

-- This includes:
-- * the wild ideas
-- * the ideas in topic
findIdeasBySpace :: IdeaSpace -> Query [Idea]
findIdeasBySpace = fmap noDeletedIdeas . findAllInBy dbIdeas (ideaLocation . ideaLocationSpace)

findComment' :: AUID Idea -> [AUID Comment] -> AUID Comment -> MQuery Comment
findComment' iid parents = preview . dbComment' iid parents

findComment :: CommentKey -> MQuery Comment
findComment ck = findComment' (ck ^. ckIdeaId) (ck ^. ckParents) (ck ^. ckCommentId)

instance FromProto IdeaLike where
    fromProto p m = IdeaLike m Like (_protoIdeaLikeDelegate p)

-- | The user whose vote is cast is passed is given as an explicit arg.  The user who actually casts
-- it for her is hidden in the 'IdeaLikeProto'.
--
-- FIXME: Assumption: the given @AUID Idea@ MUST be in the DB.
addLikeToIdea :: AUID Idea -> User -> AddDb IdeaLike
addLikeToIdea iid delegatee =
    addDb' (const (mkIdeaVoteLikeKey iid delegatee))
           (dbIdeaMap . at iid . _Just . ideaLikes)

-- | Taking back a like for the given user.  (If there is no 'IdeaLikeValue' for this user, none
-- will be created.)
delikeIdea :: AUID Idea -> AUID User -> AUpdate ()
delikeIdea iid uid =
    withIdea iid . ideaLikes . at uid . _Just . ideaLikeValue .= Delike

mkIdeaVoteLikeKey :: Applicative f => AUID Idea -> User -> f IdeaVoteLikeKey
mkIdeaVoteLikeKey i u = pure $ IdeaVoteLikeKey i (u ^. _Id)

instance FromProto IdeaVote where
    fromProto p m = IdeaVote { _ideaVoteMeta     = m
                             , _ideaVoteValue    = _protoIdeaVoteValue p
                             , _ideaVoteDelegate = _protoIdeaVoteDelegate p
                             }

-- | Analogous to 'addLikeToIdea'.
addVoteToIdea :: AUID Idea -> User -> AddDb IdeaVote
addVoteToIdea iid delegatee =
    addDb' (const (mkIdeaVoteLikeKey iid delegatee))
           (dbIdeaMap . at iid . _Just . ideaVotes)

-- Removes the vote of the given user.
removeVoteFromIdea :: AUID Idea -> AUID User -> AUpdate ()
removeVoteFromIdea iid uid = withIdea iid . ideaVotes . at uid .= Nothing

instance FromProto Comment where
    fromProto d m = Comment { _commentMeta      = m
                            , _commentText      = unCommentContent d
                            , _commentReplies   = nil
                            , _commentVotes     = nil
                            , _commentDeleted   = False
                            }


-- | FIXME: Assumption: the given @AUID Idea@ MUST be in the DB.
addCommentToIdea :: IdeaLocation -> AUID Idea -> AddDb Comment
addCommentToIdea loc iid = addDb' (nextCommentKey loc iid) (dbIdeaMap . at iid . _Just . ideaComments)

setCommentDesc :: CommentKey -> Document -> AUpdate ()
setCommentDesc ck desc =
    dbComment' (ck ^. ckIdeaId) (ck ^. ckParents) (ck ^. ckCommentId)
    . commentText .= desc

nextCommentKey :: IdeaLocation -> AUID Idea -> User -> AUpdate CommentKey
nextCommentKey loc iid _ = CommentKey loc iid [] <$> nextId

nextReplyId :: CommentKey -> User -> AUpdate CommentKey
nextReplyId ck _ = do
    i <- nextId
    pure $ ck & ckParents  <>~ [ck ^. ckCommentId]
              & ckCommentId .~ i

-- | FIXME: Assumptions:
-- * the given @CommentKey@ MUST be in the DB.
addReply :: CommentKey -> AddDb Comment
addReply ck = addDb' (nextReplyId ck) (dbComment ck . commentReplies)

instance FromProto CommentVote where
    fromProto = flip CommentVote

-- | FIXME: Assumptions:
-- * the given @CommentKey@ MUST be in the DB.
addCommentVote :: CommentKey -> AddDb CommentVote
addCommentVote ck = addDb' (mkCommentVoteKey ck) (dbComment ck . commentVotes)

mkCommentVoteKey :: Applicative f => CommentKey -> User -> f CommentVoteKey
mkCommentVoteKey ck u = pure $ CommentVoteKey ck (u ^. _Id)

instance FromProto IdeaJuryResult where
    fromProto = flip IdeaJuryResult

addIdeaJuryResult :: AUID Idea -> AddDb IdeaJuryResult
addIdeaJuryResult iid =
    addDbAppValue (dbIdeaMap . at iid . _Just . ideaJuryResult)

removeIdeaJuryResult :: AUID Idea -> AUpdate ()
removeIdeaJuryResult iid = withIdea iid . ideaJuryResult .= Nothing

setCreatorStatement :: AUID Idea -> Document -> AUpdate ()
setCreatorStatement iid statement =
    withIdea iid . ideaVoteResult . _Just . ideaVoteResultValue . _Winning ?= statement

instance FromProto IdeaVoteResult where
    fromProto = flip IdeaVoteResult

addIdeaVoteResult :: AUID Idea -> AddDb IdeaVoteResult
addIdeaVoteResult iid =
    addDbAppValue (dbIdeaMap . at iid . _Just . ideaVoteResult)

revokeWinnerStatus :: AUID Idea -> AUpdate ()
revokeWinnerStatus iid = withIdea iid . ideaVoteResult .= Nothing

dbComment' :: AUID Idea -> [AUID Comment] -> AUID Comment -> AulaTraversal Comment
dbComment' iid parents ck =
    dbIdeaMap . at iid . _Just . ideaComments . traverseParents parents . at ck . _Just

dbComment :: CommentKey -> AulaTraversal Comment
dbComment ck = dbComment' (ck ^. ckIdeaId) (ck ^. ckParents) (ck ^. ckCommentId)

deleteComment :: CommentKey -> AUpdate ()
deleteComment ck = dbComment ck . commentDeleted .= True


nextId :: AUpdate (AUID a)
nextId = AUID <$> (dbLastId <+= 1)

-- | No 'FromProto' instance, since this is more complex, due to the possible
-- auto-generating of logins and passwords.
userFromProto :: MetaInfo User -> UserLogin -> InitialPassword -> Proto User -> User
userFromProto metainfo uLogin uPassword proto = User
    { _userMeta      = metainfo
    , _userLogin     = uLogin
    , _userFirstName = proto ^. protoUserFirstName
    , _userLastName  = proto ^. protoUserLastName
    , _userRoleSet   = proto ^. protoUserRoleSet
    , _userSettings  = UserSettings
        { _userSettingsPassword = UserPassInitial uPassword
        , _userSettingsEmail    = proto ^. protoUserEmail
        }
    , _userDesc      = proto ^. protoUserDesc
    }

checkLoginIsAvailable :: UserLogin -> AUpdate ()
checkLoginIsAvailable li = do
    yes <- liftAQuery $ loginIsAvailable li
    unless yes . throwError $ UserLoginInUse li

loginIsAvailable :: UserLogin -> Query Bool
loginIsAvailable = fmap isNothing . findUserByLogin

addUser :: AddDb User
addUser (EnvWith cUser now proto) = do
    metainfo <- nextMetaInfo cUser now
    uLogin <- case proto ^. protoUserLogin of
        Nothing -> mkUserLoginFromProto proto
        Just li -> checkLoginIsAvailable li $> li
    let user = userFromProto metainfo uLogin (proto ^. protoUserPassword) proto
    dbUserMap . at (user ^. _Id) <?= user

-- | When adding the first user, there is no creator yet, so the first user creates itself.  Login
-- name and password must be 'Just' in the proto user.
addFirstUser :: Timestamp -> Proto User -> AUpdate User
addFirstUser now proto = do
    uid <- nextId
    let uLogin    = fromMaybe (error "addFirstUser: no login name") (proto ^. protoUserLogin)
        -- the user creates herself
        cUser = _Id .~ uid $ user
        metainfo = mkMetaInfo cUser now uid
        user = userFromProto metainfo uLogin (proto ^. protoUserPassword) proto

    dbUserMap . at (user ^. _Id) <?= user

genUserLoginCandidates :: UserFirstName -> UserLastName -> [ST]
genUserLoginCandidates
    (pruneAndPad 3 . ST.filter usernameAllowedChar . view unUserFirstName -> fn)
    (pruneAndPad 3 . ST.filter usernameAllowedChar . view unUserLastName  -> ln)
        = mutate (fn <> ln) <$> noise
  where
    mutate :: ST -> ST -> ST
    mutate sig noi = ST.take (6 - ST.length noi) sig <> noi

    noise :: [ST]
    noise = nub $ cs . mconcat <$> replicateM 5 ("" : ((:[]) <$> ['a'..'z']))

pruneAndPad :: Int -> ST -> ST
pruneAndPad i s = ST.take i $ s <> cs (replicate i 'o')


mkUserLoginFromProto :: ProtoUser -> AUpdate UserLogin
mkUserLoginFromProto protoUser = pick $ genUserLoginCandidates
    (protoUser ^. protoUserFirstName)
    (protoUser ^. protoUserLastName)
  where
    pick :: [ST] -> AUpdate UserLogin
    pick ((mkUserLogin -> l):ls) = maybe (pure l) (\_ -> pick ls) =<< liftAQuery (findUserByLogin l)
    pick []                      = error "impossible.  (well, unlikely.)"
                                 -- FIXME: use throwError(500) here?

instance FromProto Idea where
    fromProto i m = Idea
        { _ideaMeta       = m
        , _ideaTitle      = i ^. protoIdeaTitle
        , _ideaDesc       = i ^. protoIdeaDesc
        , _ideaCategory   = i ^. protoIdeaCategory
        , _ideaLocation   = i ^. protoIdeaLocation
        , _ideaComments   = nil
        , _ideaLikes      = nil
        , _ideaVotes      = nil
        , _ideaJuryResult = Nothing
        , _ideaVoteResult = Nothing
        , _ideaDeleted    = False
        }

instance FromProto Topic where
    fromProto t m = Topic
        { _topicMeta      = m
        , _topicTitle     = t ^. protoTopicTitle
        , _topicDesc      = t ^. protoTopicDesc
        , _topicImage     = t ^. protoTopicImage
        , _topicIdeaSpace = t ^. protoTopicIdeaSpace
        , _topicPhase     = PhaseRefinement . ActivePhase $ t ^. protoTopicRefPhaseEnd
        , _topicDeleted   = False
        }

mkMetaInfo :: User -> Timestamp -> KeyOf a -> MetaInfo a
mkMetaInfo cUser now key = MetaInfo
    { _metaKey             = key
    , _metaCreatedBy       = cUser ^. _Id
    , _metaCreatedByLogin  = cUser ^. userLogin
    , _metaCreatedAt       = now
    , _metaChangedBy       = cUser ^. _Id
    , _metaChangedAt       = now
    }

nextMetaInfo :: KeyOf a ~ AUID a => User -> Timestamp -> AUpdate (MetaInfo a)
nextMetaInfo user now = mkMetaInfo user now <$> nextId

editIdea :: AUID Idea -> ProtoIdea -> AUpdate ()
editIdea ideaId protoIdea = withIdea ideaId %= (ideaTitle     .~ (protoIdea ^. protoIdeaTitle))
                                             . (ideaDesc      .~ (protoIdea ^. protoIdeaDesc))
                                             . (ideaCategory  .~ (protoIdea ^. protoIdeaCategory))

deleteIdea :: AUID Idea -> AUpdate ()
deleteIdea ideaId =
    withIdea ideaId %= (ideaDeleted .~ True)
                     . over ideaComments (Map.map (set commentDeleted True))

deleteTopic :: AUID Topic -> AUpdate ()
deleteTopic topicId = do
    topic <- maybe404 =<< liftAQuery (findTopic topicId)
    previouslyInTopic :: [AUID Idea] <- view _Id <$$> liftAQuery (findIdeasByTopicId topicId)
    void $ moveIdeasToLocation previouslyInTopic (IdeaLocationSpace (topic ^. topicIdeaSpace))
    withTopic topicId %= (topicDeleted .~ True)

termsOfUse :: Query Document
termsOfUse = view dbTermsOfUse

setTermsOfUse :: Document -> AUpdate ()
setTermsOfUse doc = void $ dbTermsOfUse <.= doc

wipeIdeasAndTopics :: AUpdate ()
wipeIdeasAndTopics = do
    topics <- use $ dbTopicMap . to Map.keys
    dbIdeaMap  .= Map.empty
    dbTopicMap .= Map.empty
    forM_ topics $ \topic -> dbDelegations %= removeDelegationsByScope (DScopeTopicId topic)

dbDurations :: Lens' AulaData Durations
dbQuorums   :: Lens' AulaData Quorums
dbFreeze    :: Lens' AulaData Freeze

dbDurations = dbSettings . durations
dbQuorums   = dbSettings . quorums
dbFreeze    = dbSettings . freeze

dbElaborationDuration :: Lens' AulaData DurationDays
dbVoteDuration        :: Lens' AulaData DurationDays
dbSchoolQuorum        :: Lens' AulaData Percent
dbClassQuorum         :: Lens' AulaData Percent

dbElaborationDuration = dbDurations . elaborationPhase
dbVoteDuration        = dbDurations . votingPhase
dbSchoolQuorum        = dbQuorums   . schoolQuorumPercentage
dbClassQuorum         = dbQuorums   . classQuorumPercentage

saveDurations :: Durations -> AUpdate ()
saveDurations = (dbDurations .=)

saveQuorums :: Quorums -> AUpdate ()
saveQuorums = (dbQuorums .=)

dangerousResetAulaData :: AUpdate ()
dangerousResetAulaData = put emptyAulaData

dangerousRenameAllLogins :: ST -> AUpdate ()
dangerousRenameAllLogins suffix = aulaUserLogins . _UserLogin <>= suffix

fixComment :: IdeaLocation -> Comment -> Comment
fixComment loc comment = comment
    & commentMeta . metaKey . ckIdeaLocation .~ loc
    & commentVotes . each . commentVoteMeta . metaKey . cvCommentKey . ckIdeaLocation .~ loc
    & commentReplies . each %~ fixComment loc

fixIdea :: Idea -> Idea
fixIdea idea = idea & ideaComments . each %~ fixComment (idea ^. ideaLocation)

fixAulaData :: AulaData -> AulaData
fixAulaData = dbIdeaMap . each %~ fixIdea

fixAulaDataUpdate :: AUpdate ()
fixAulaDataUpdate = modify fixAulaData

makeLenses ''IdeaChangedLocation
