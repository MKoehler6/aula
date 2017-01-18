{-# LANGUAGE ConstraintKinds             #-}
{-# LANGUAGE DataKinds                   #-}
{-# LANGUAGE DeriveDataTypeable          #-}
{-# LANGUAGE DeriveGeneric               #-}
{-# LANGUAGE FlexibleContexts            #-}
{-# LANGUAGE FlexibleInstances           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving  #-}
{-# LANGUAGE KindSignatures              #-}
{-# LANGUAGE LambdaCase                  #-}
{-# LANGUAGE MultiParamTypeClasses       #-}
{-# LANGUAGE OverloadedStrings           #-}
{-# LANGUAGE Rank2Types                  #-}
{-# LANGUAGE ScopedTypeVariables         #-}
{-# LANGUAGE TypeFamilies                #-}
{-# LANGUAGE TypeOperators               #-}
{-# LANGUAGE TypeSynonymInstances        #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module Types.Core
where

import Control.Lens hiding ((<.>))
import Data.Char
import Data.Data (Data)
import Data.Function (on)
import Data.Set as Set (Set)
import Data.Map as Map (Map)
import Data.Proxy (Proxy(Proxy))
import Data.String
import Data.String.Conversions
import Data.Typeable (Typeable)
import Data.UriPath (HasUriPart(uriPart))
import GHC.Generics (Generic)
import Network.HTTP.Media ((//))
import Servant.API
    ( FromHttpApiData(parseUrlPiece), ToHttpApiData(toUrlPiece)
    , Accept, MimeRender, Headers(..), Header, contentType, mimeRender, addHeader
    )
import System.FilePath ((</>), (<.>))
import Text.Read (readMaybe)

import qualified Codec.Archive.Zip as Zip
import qualified Data.Csv as CSV
import qualified Data.Text as ST
import qualified Text.Email.Validate as Email

import Types.Prelude
import Data.Markdown
import Frontend.Constant


-- * prototypes for types

-- | Prototype for a type.
-- The prototypes contains all the information which cannot be
-- filled out of some type. Information which comes from outer
-- source and will be saved into the database.
--
-- FIXME: move this into 'FromProto'?
type family Proto type_ :: *

-- | The method how a 't' value is calculated from its prototype
-- and a metainfo to that.
class FromProto t where
    fromProto :: Proto t -> MetaInfo t -> t


-- * metainfo

-- | General information on objects stored in the DB.
--
-- Some of these fields, like login name and avatar url of creator, are redundant.  The reason to
-- keep them here is that it makes it easy to keep large 'Page*' types containing many nested
-- objects, and still allowing all these objects to be rendered purely only based on the information
-- they contain.
--
-- If this is becoming too much in the future and we want to keep objects around without all this
-- inlined information, we should consider making objects polymorphic in the concrete meta info
-- type.  Example: 'Idea MetaInfo', but also 'Idea ShortMetaInfo'.
-- np@2016-04-18: Actually `Idea MetaInfo` does not work well. Parameters of kind `* -> *` are not
-- well supported by generics and deriving mechanisms.
data GMetaInfo a k = MetaInfo
    { _metaKey             :: k
    , _metaCreatedBy       :: AUID User
    , _metaCreatedByLogin  :: UserLogin
    , _metaCreatedAt       :: Timestamp
    , _metaChangedBy       :: AUID User
    , _metaChangedAt       :: Timestamp
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

type MetaInfo a = GMetaInfo a (KeyOf a)


-- * database keys

-- | Aula Unique ID for reference in the database.  This is unique for one concrete phantom type
-- only and will probably be generated by sql `serial` type.
newtype AUID a = AUID { _unAUID :: Integer }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data, FromHttpApiData, Enum, Real, Num, Integral)

type family   KeyOf a
type instance KeyOf User             = AUID User
type instance KeyOf Idea             = AUID Idea
type instance KeyOf IdeaVote         = IdeaVoteLikeKey
type instance KeyOf IdeaLike         = IdeaVoteLikeKey
type instance KeyOf IdeaVoteResult   = AUID IdeaVoteResult
type instance KeyOf IdeaJuryResult   = AUID IdeaJuryResult
type instance KeyOf Topic            = AUID Topic
type instance KeyOf Delegation       = AUID Delegation
type instance KeyOf Comment          = CommentKey
type instance KeyOf CommentVote      = CommentVoteKey

-- | Extracts the identifier (AUID) from a key (KeyOf).
-- The identifier corresponds to the key of the last map (AMap).
--
-- For some types such as User, the key and the identifier are identical.
--
-- For a comment vote, the key is a composite of the comment key and the user id.
-- The identifier of a comment vote is only the user id part of the key.
--
-- So far all identifiers are of type AUID we shall try to keep it that way.
type family   IdOfKey a
type instance IdOfKey (AUID a)        = AUID a
type instance IdOfKey CommentKey      = AUID Comment
type instance IdOfKey CommentVoteKey  = AUID User
type instance IdOfKey IdeaVoteLikeKey = AUID User

type IdOf a = IdOfKey (KeyOf a)


-- * database maps

type AMap a = Map (IdOf a) a

type Users        = AMap User
type Ideas        = AMap Idea
type Topics       = AMap Topic
type Comments     = AMap Comment
type CommentVotes = AMap CommentVote
type IdeaVotes    = AMap IdeaVote
type IdeaLikes    = AMap IdeaLike


-- * user

data User = User
    { _userMeta      :: MetaInfo User
    , _userLogin     :: UserLogin
    , _userFirstName :: UserFirstName
    , _userLastName  :: UserLastName
    , _userRoleSet   :: Set Role
    , _userDesc      :: Document
    , _userSettings  :: UserSettings
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

newtype UserLogin     = UserLogin     { _unUserLogin     :: ST }
  deriving (Eq, Ord, Show, Read, IsString, Monoid, Generic, Typeable, Data, FromHttpApiData)

mkUserLogin :: ST -> UserLogin
mkUserLogin = UserLogin . ST.toLower

usernameAllowedChar :: Char -> Bool
usernameAllowedChar = (`elem` ['a'..'z']) . toLower

classnameAllowedChar :: Char -> Bool
classnameAllowedChar = (`elem` (['a'..'z'] <> ['0'..'9'] <> ['_', '-'])) . toLower

newtype UserFirstName = UserFirstName { _unUserFirstName :: ST }
  deriving (Eq, Ord, Show, Read, IsString, Monoid, Generic, Typeable, Data, FromHttpApiData)

newtype UserLastName  = UserLastName  { _unUserLastName  :: ST }
  deriving (Eq, Ord, Show, Read, IsString, Monoid, Generic, Typeable, Data, FromHttpApiData)

data UserSettings = UserSettings
    { _userSettingsPassword :: UserPass
    , _userSettingsEmail    :: Maybe EmailAddress
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

newtype EmailAddress = InternalEmailAddress { internalEmailAddress :: Email.EmailAddress }
    deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

data UserPass =
    UserPassInitial   { _userPassInitial   :: InitialPassword }
  | UserPassEncrypted { _userPassEncrypted :: EncryptedPassword }
  | UserPassDeactivated
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

newtype InitialPassword = InitialPassword { _unInitialPassword :: ST }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

newtype EncryptedPassword = ScryptEncryptedPassword { _unScryptEncryptedPassword :: SBS }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)


-- | Users are never deleted, just marked as deleted.
data UserView
    = ActiveUser  { _activeUser  :: User }
    | DeletedUser { _deletedUser :: User }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

data ProtoUser = ProtoUser
    { _protoUserLogin     :: Maybe UserLogin
    , _protoUserFirstName :: UserFirstName
    , _protoUserLastName  :: UserLastName
    , _protoUserRoleSet   :: Set Role
    , _protoUserPassword  :: InitialPassword
    , _protoUserEmail     :: Maybe EmailAddress
    , _protoUserDesc      :: Document
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

type instance Proto User = ProtoUser


-- * role

-- | Note that all roles except 'Student' and 'ClassGuest' have the same access to all IdeaSpaces.
-- (Rationale: e.g. teachers have trust each other and can cover for each other.)
data Role =
    Student    { _roleSchoolClass :: Maybe SchoolClass }
  | ClassGuest { _roleSchoolClass :: Maybe SchoolClass } -- ^ e.g., parents
  | SchoolGuest  -- ^ e.g., researchers
  | Moderator
  | Principal
  | Admin
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

parseRole :: (IsString err, Monoid err) => [ST] -> Either err Role
parseRole = \case
    ["admin"]      -> pure Admin
    ["principal"]  -> pure Principal
    ["moderator"]  -> pure Moderator
    ["student"]    -> pure $ Student Nothing
    ("student":xs) -> Student . Just <$> parseSchoolClassCode xs
    ["guest"]      -> pure $ ClassGuest Nothing
    ("guest":xs)   -> guestRole <$> parseIdeaSpaceCode xs
    _              -> Left "Ill-formed role"

parseIdeaSpaceCode :: (IsString err, Monoid err) => [ST] -> Either err IdeaSpace
parseIdeaSpaceCode = \case
    ["school"] -> pure SchoolSpace
    xs         -> ClassSpace <$> parseSchoolClassCode xs

parseIdeaSpaceCode' :: (IsString err, Monoid err) => ST -> Either err IdeaSpace
parseIdeaSpaceCode' = parseIdeaSpaceCode . ST.splitOn "-"

parseSchoolClassCode :: (IsString err, Monoid err) => [ST] -> Either err SchoolClass
parseSchoolClassCode = \case
    (year : name) -> (`SchoolClass` ClassName (ST.intercalate "-" name)) <$> readYear year
                      -- (splitOn-then-intercalate is not pretty, but there is nothing better
                      -- fitting in the ST module for what we actually need here, and we don't want
                      -- to spend time writing more aux functions, again.)
    _             -> err "Too few parts (two parts expected)"
  where
    err msg = Left $ "Ill-formed school class: " <> msg
    readYear = maybe (err "Year should be only digits") Right . readMaybe . cs

parseSchoolClassCode' :: (IsString err, Monoid err) => ST -> Either err SchoolClass
parseSchoolClassCode' = parseSchoolClassCode . ST.splitOn "-"

guestRole :: IdeaSpace -> Role
guestRole = \case
    SchoolSpace  -> SchoolGuest
    ClassSpace c -> ClassGuest (Just c)


-- * idea

-- | "Idee".  Ideas can be either be wild or contained in exactly one 'Topic'.
data Idea = Idea
    { _ideaMeta       :: MetaInfo Idea
    , _ideaTitle      :: ST
    , _ideaDesc       :: Document
    , _ideaCategory   :: Maybe Category
    , _ideaLocation   :: IdeaLocation
    , _ideaComments   :: Comments
    , _ideaLikes      :: IdeaLikes
    , _ideaVotes      :: IdeaVotes
    , _ideaJuryResult :: Maybe IdeaJuryResult  -- invariant: isJust => phase of containing topic > JuryPhsae
    , _ideaVoteResult :: Maybe IdeaVoteResult  -- invariant: isJust => phase of containing topic > VotingPhase
    , _ideaDeleted    :: Bool
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

-- | Invariant: for all @IdeaLocationTopic space tid@: idea space of topic with id 'tid' is 'space'.
data IdeaLocation =
      IdeaLocationSpace { _ideaLocationSpace :: IdeaSpace }
    | IdeaLocationTopic { _ideaLocationSpace :: IdeaSpace, _ideaLocationTopicId :: AUID Topic }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

-- | Prototype for Idea creation.
data ProtoIdea = ProtoIdea
    { _protoIdeaTitle      :: ST
    , _protoIdeaDesc       :: Document
    , _protoIdeaCategory   :: Maybe Category
    , _protoIdeaLocation   :: IdeaLocation
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

type instance Proto Idea = ProtoIdea

-- | "Kategorie"
data Category =
    CatRules        -- ^ "Regel"
  | CatEquipment    -- ^ "Ausstattung"
  | CatActivities   -- ^ "Aktivitäten"
  | CatTeaching     -- ^ "Unterricht"
  | CatTime         -- ^ "Zeit"
  | CatEnvironment  -- ^ "Umgebung"
  deriving (Eq, Ord, Bounded, Enum, Show, Read, Generic, Typeable, Data)

-- | With delegation of likes, a unit type isn't enough for this, we need a boolean.  If a delegate
-- de-likes an idea, the delegatees should only follow if they haven't made up their own mind
-- earlier.  In order to make this distinction, we need to store the delegate together with each
-- delegatee and like value.
data IdeaLikeValue =
    Like
  | Delike -- ^ Like taken back
  deriving (Eq, Ord, Bounded, Enum, Show, Read, Generic, Typeable, Data)

-- | endorsement, or interest.
data IdeaLike = IdeaLike
    { _ideaLikeMeta     :: MetaInfo IdeaLike
    , _ideaLikeValue    :: IdeaLikeValue
    , _ideaLikeDelegate :: AUID User
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

data ProtoIdeaLike = ProtoIdeaLike
    { _protoIdeaLikeDelegate :: AUID User
    }

type instance Proto IdeaLike = ProtoIdeaLike

-- | "Stimme" for "Idee".  As opposed to 'CommentVote'.
data IdeaVote = IdeaVote
    { _ideaVoteMeta     :: MetaInfo IdeaVote
    , _ideaVoteValue    :: IdeaVoteValue
    , _ideaVoteDelegate :: AUID User
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

data ProtoIdeaVote = ProtoIdeaVote
    { _protoIdeaVoteValue    :: IdeaVoteValue
    , _protoIdeaVoteDelegate :: AUID User
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

type instance Proto IdeaVote = ProtoIdeaVote

data IdeaVoteValue = Yes | No
  deriving (Eq, Ord, Enum, Bounded, Show, Read, Generic, Typeable, Data)

data IdeaVoteLikeKey = IdeaVoteLikeKey
    { _ivIdea :: AUID Idea
    , _ivUser :: AUID User
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

data IdeaJuryResult = IdeaJuryResult
    { _ideaJuryResultMeta   :: MetaInfo IdeaJuryResult
    , _ideaJuryResultValue  :: IdeaJuryResultValue
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

data IdeaJuryResultType
    = IdeaNotFeasible
    | IdeaFeasible
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

data IdeaJuryResultValue
    = NotFeasible { _ideaResultNotFeasibleReason :: Document }
    | Feasible    { _ideaResultFeasibleReason    :: Maybe Document }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

type instance Proto IdeaJuryResult = IdeaJuryResultValue

ideaResultReason :: Traversal' IdeaJuryResultValue Document
ideaResultReason f = \case
    NotFeasible d -> NotFeasible <$> f d
    Feasible md   -> Feasible <$> traverse f md

data IdeaVoteResult = IdeaVoteResult
    { _ideaVoteResultMeta   :: MetaInfo IdeaVoteResult
    , _ideaVoteResultValue  :: IdeaVoteResultValue
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

data IdeaVoteResultValue
    = Winning { _ideaResultCreatorStatement :: Maybe Document }
    | EnoughVotes Bool
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

type instance Proto IdeaVoteResult = IdeaVoteResultValue


-- * comment

-- | "Verbesserungsvorschlag"
--
-- 'Comments' are hierarchical.  The application logic is responsible for putting some limit (if
-- any) on the recursion depth under which all children become siblings.
--
-- A comment has no implicit 'yes' vote by the author.  This gives the author the option of voting
-- for a comment, or even against it.  Even though the latter may never make sense, somebody may
-- still learn something from trying it out, and this is a teaching application.
data Comment = Comment
    { _commentMeta    :: MetaInfo Comment
    , _commentText    :: Document
    , _commentVotes   :: CommentVotes
    , _commentReplies :: Comments
    , _commentDeleted :: Bool
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)


-- | This is the complete information to recover a comment in AulaData
-- * ckParents: Comment identifiers from the root to the leaf. If `y`, follows `x` in ckParents,
--              then `y` is a reply to `x`. See also `traverseParents` for a use of that field.
data CommentKey = CommentKey
    { _ckIdeaLocation  :: IdeaLocation
    , _ckIdeaId        :: AUID Idea
    , _ckParents       :: [AUID Comment]
    , _ckCommentId     :: AUID Comment
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

commentKey :: IdeaLocation -> AUID Idea -> AUID Comment -> CommentKey
commentKey loc iid = CommentKey loc iid []

replyKey :: IdeaLocation -> AUID Idea -> AUID Comment -> AUID Comment -> CommentKey
replyKey loc iid pid = CommentKey loc iid [pid]

data CommentVoteKey = CommentVoteKey
    { _cvCommentKey :: CommentKey
    , _cvUser      :: AUID User
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

newtype CommentContent = CommentContent { unCommentContent :: Document }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

type instance Proto Comment = CommentContent

-- | "Stimme" for "Verbesserungsvorschlag"
data CommentVote = CommentVote
    { _commentVoteMeta  :: MetaInfo CommentVote
    , _commentVoteValue :: UpDown
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

data UpDown = Up | Down
  deriving (Eq, Ord, Show, Read, Enum, Bounded, Generic, Typeable, Data)

type instance Proto CommentVote = UpDown

data CommentContext = CommentContext
    { _parentIdea    :: Idea
    , _parentComment :: Maybe Comment
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)


-- * idea space, topic, phase

-- | "Ideenraum" is one of "Klasse", "Schule".
data IdeaSpace =
    SchoolSpace
  | ClassSpace { _ideaSpaceSchoolClass :: SchoolClass }
  deriving (Eq, Show, Read, Generic, Typeable, Data)

newtype ClassName = ClassName { _unClassName :: ST }
  deriving (Eq, Ord, Show, Read, IsString, Monoid, Generic, Typeable, Data, FromHttpApiData)

-- | "Klasse".  (The school year is necessary as the class name is used for a fresh set of students
-- every school year.)
data SchoolClass = SchoolClass
    { _classSchoolYear :: Int       -- ^ e.g. 2015
    , _className       :: ClassName -- ^ e.g. "7a"
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

-- | FIXME: needs to be gone by the end of school year 2016!
theOnlySchoolYearHack :: Int
theOnlySchoolYearHack = 2016


ideaSpaceCode :: IdeaSpace -> String
ideaSpaceCode SchoolSpace    = "school"
ideaSpaceCode (ClassSpace c) = schoolClassCode c

schoolClassCode :: SchoolClass -> String
schoolClassCode c = show (_classSchoolYear c) <> "-" <> cs (_unClassName (_className c))


-- | A 'Topic' is created inside an 'IdeaSpace'.  It is used as a container for a "wild idea" that
-- has reached a quorum, plus more ideas that the moderator decides belong here.  'Topic's have
-- 'Phase's.  All 'Idea's in a 'Topic' must have the same 'IdeaSpace' as the 'Topic'.
data Topic = Topic
    { _topicMeta      :: MetaInfo Topic
    , _topicTitle     :: ST
    , _topicDesc      :: PlainDocument
    , _topicImage     :: URL
    , _topicIdeaSpace :: IdeaSpace
    , _topicPhase     :: Phase
    , _topicDeleted   :: Bool
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

data ProtoTopic = ProtoTopic
    { _protoTopicTitle       :: ST
    , _protoTopicDesc        :: PlainDocument
    , _protoTopicImage       :: URL
    , _protoTopicIdeaSpace   :: IdeaSpace
    , _protoTopicIdeas       :: [AUID Idea]
    , _protoTopicRefPhaseEnd :: Timestamp
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

type instance Proto Topic = ProtoTopic


-- * topic phases

data PhaseStatus
  = ActivePhase { _phaseEnd :: Timestamp }
  | FrozenPhase { _phaseLeftover :: Timespan }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

-- | Topic phases.  (Phase 1.: "wild ideas", is where 'Topic's are born, and we don't need a
-- constructor for that here.)
data Phase =
    PhaseWildIdea   { _phaseWildFrozen :: Freeze }
  | PhaseRefinement { _phaseStatus :: PhaseStatus }
                               -- ^ 2. "Ausarbeitungsphase"
  | PhaseJury                  -- ^ 3. "Prüfungsphase"
  | PhaseVoting     { _phaseStatus :: PhaseStatus }
                               -- ^ 4. "Abstimmungsphase"
  | PhaseResult                -- ^ 5. "Ergebnisphase"
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

data Freeze = NotFrozen | Frozen
  deriving (Eq, Ord, Show, Read, Enum, Bounded, Generic, Typeable, Data)


-- * delegations

data DelegationNetwork = DelegationNetwork
    { _networkUsers         :: [(User, Int)]  -- ^ 'User's and their 'votingPower's.
    , _networkDelegations   :: [Delegation]
    }
  deriving (Eq, Show, Read, Generic, Typeable, Data)

-- | "Beauftragung"
data Delegation = Delegation
    { _delegationScope :: DScope
    , _delegationFrom  :: AUID User
    , _delegationTo    :: AUID User
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

data DelegationFull = DelegationFull
    { _delegationFullScope :: DScope
    , _delegationFullFrom  :: User
    , _delegationFullTo    :: User
    }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

type instance Proto Delegation = Delegation

-- | Node type for the delegation scope hierarchy DAG.  The four levels are 'Idea', 'Topic',
-- 'SchoolClass', and global.
--
-- There 'SchoolClass' level could reference an 'IdeaSpace' instead, but there is a subtle
-- difference between delegation in school space and globally that we would like to avoid having to
-- explain to our users, so we do not allow delegation in school space, and collapse 'school' and
-- 'global' liberally in the UI.  We enforce this collapse in this type.
--
-- Example to demonstrate the difference: If idea @A@ lives in class @C@, and user @X@ votes yes on
-- @A@, consider the two cases: If I delegate to user @X@ on school space level, @A@ is not covered,
-- because it lives in a different space, so user @X@ does *not* cast my vote.  If I delegate to
-- user @X@ *globally*, @A@ *is* covered, and @X@ *does* cast my vote.
--
-- The reason for this confusion is related to idea space membership, which is different for school:
-- every user is implicitly a member of the idea space "school", whereas membership in all other
-- idea spaces is explicit in the role.  However, this does not necessarily (although
-- coincidentally) constitute a subset relationship between class spaces and school space.
data DScope =
    DScopeIdeaSpace { _dScopeIdeaSpace :: IdeaSpace  }
  | DScopeTopicId   { _dScopeTopicId   :: AUID Topic }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

-- | 'DScope', but with the references resolved.  (We could do a more general type @DScope a@ and
-- introduce two synonyms for @DScope AUID@ and @DScope Identity@, but it won't make things any
-- easier.)
data DScopeFull =
    DScopeIdeaSpaceFull { _dScopeIdeaSpaceFull :: IdeaSpace }
  | DScopeTopicFull     { _dScopeTopicFull     :: Topic     }
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)


-- * avatar locators

type AvatarDimension = Int

avatarPng :: Maybe AvatarDimension -> AUID a -> FilePath
avatarPng mdim uid = cs (uriPart uid) <> sdim <.> "png"
  where
    sdim = mdim ^. _Just . showed . to ("-" <>)

avatarFile :: FilePath -> Maybe AvatarDimension -> Getter (AUID a) FilePath
avatarFile avatarsDir mdim = to $ \uid -> avatarsDir </> avatarPng mdim uid

-- | See "Frontend.Constant.avatarDefaultSize"
avatarUrl :: AvatarDimension -> Getter (AUID a) URL
avatarUrl dim = to (\uid -> "/avatar" </> avatarPng mdim uid) . csi
  where
    mdim | dim == avatarDefaultSize = Nothing
         | otherwise                = Just dim

userAvatar :: AvatarDimension -> Getter User URL
userAvatar dim = to _userMeta . to _metaKey . avatarUrl dim


-- * csv helpers

-- | since some browsers try to be difficult about downloading csv files as files (rather than
-- displaying them as text), always deliver them wrapped in a zip file.
data CSVZIP

instance Accept CSVZIP where
    contentType Proxy = "application" // "zip"  -- (without zip: "text" // "csv")

type ContentDisposition = "Content-Disposition"  -- appease hlint v1.9.22
type AttachmentHeaders a = Headers '[Header ContentDisposition String] a

instance MimeRender CSVZIP a => MimeRender CSVZIP (AttachmentHeaders a) where
    mimeRender proxy (Headers v _) = mimeRender proxy v

-- FIXME Escaping?
attachmentHeaders :: String -> a -> AttachmentHeaders a
attachmentHeaders filename = addHeader $ "attachment; filename=" <> filename

zipLbs :: Timestamp -> FilePath -> LBS -> LBS
zipLbs now fname content =
    Zip.fromArchive $ Zip.Archive
        [Zip.toEntry fname (timestampToEpoch now) content] Nothing ""


-- * xlsx helpers

data XLSX

instance Accept XLSX where
    contentType Proxy = "application" // "vnd.openxmlformats-officedocument.spreadsheetml.sheet"


-- * misc

newtype DurationDays = DurationDays { unDurationDays :: Int }
  deriving (Eq, Ord, Show, Read, Num, Enum, Real, Integral, Generic, Typeable, Data)


-- | Percentage values from 0 to 100, used in quorum computations.
type Percent = Int


-- | Transform values into strings suitable for presenting to the user.  These strings are not
-- machine-readable in general.  (alternative names that lost in a long bikeshedding session:
-- @HasUIString@, @HasUIText@, ...)
class HasUILabel a where
    uilabel :: a -> (Monoid s, IsString s) => s

    uilabelST :: a -> ST
    uilabelST = uilabel

    uilabeled :: (Monoid s, IsString s) => Getter a s
    uilabeled = to uilabel

    uilabeledST :: Getter a ST
    uilabeledST = to uilabel


-- * instances

instance HasUriPart (AUID a) where
    uriPart (AUID s) = fromString . show $ s


-- ** user, role

instance CSV.FromField EmailAddress where
    parseField f = either fail (pure . InternalEmailAddress) . Email.validate =<< CSV.parseField f

instance FromHttpApiData Role where
    parseUrlPiece = parseRole . ST.splitOn "-"

instance HasUILabel Role where
    uilabel = \case
        Student Nothing     -> "Schüler"
        Student (Just c)    -> "Schüler (" <> uilabel c <> ")"
        ClassGuest Nothing  -> "Gast"
        ClassGuest (Just c) -> "Gast (" <> uilabel c <> ")"
        SchoolGuest         -> "Gast (Schule)"
        Moderator           -> "Moderator"
        Principal           -> "Direktor"
        Admin               -> "Administrator"

instance HasUriPart Role where
    uriPart = \case
        Student Nothing     -> "student"
        Student (Just c)    -> "student-" <> uriPart c
        ClassGuest Nothing  -> "guest"
        ClassGuest (Just c) -> "guest-" <> uriPart c
        SchoolGuest         -> "guest-school"
        Moderator           -> "moderator"
        Principal           -> "principal"
        Admin               -> "admin"


-- ** idea

instance HasUILabel Category where
    uilabel = \case
        CatRules       -> "Regeln"
        CatEquipment   -> "Ausstattung"
        CatActivities  -> "Aktivitäten"
        CatTeaching    -> "Unterricht"
        CatTime        -> "Zeit"
        CatEnvironment -> "Umgebung"

instance ToHttpApiData Category where
    toUrlPiece = \case
        CatRules       -> "rules"
        CatEquipment   -> "equipment"
        CatActivities  -> "activities"
        CatTeaching    -> "teaching"
        CatTime        -> "time"
        CatEnvironment -> "environment"

instance FromHttpApiData Category where
    parseUrlPiece = \case
        "rules"       -> Right CatRules
        "equipment"   -> Right CatEquipment
        "activities"  -> Right CatActivities
        "teaching"    -> Right CatTeaching
        "time"        -> Right CatTime
        "environment" -> Right CatEnvironment
        _             -> Left "no parse"


instance HasUriPart IdeaJuryResultType where
    uriPart = fromString . cs . toUrlPiece

instance ToHttpApiData IdeaJuryResultType where
    toUrlPiece = \case
      IdeaNotFeasible -> "good"
      IdeaFeasible    -> "bad"

instance FromHttpApiData IdeaJuryResultType where
    parseUrlPiece = \case
      "good" -> Right IdeaNotFeasible
      "bad"  -> Right IdeaFeasible
      _      -> Left "Ill-formed idea vote value: only `good' or `bad' are allowed"


instance HasUriPart IdeaVoteValue where
    uriPart = fromString . lowerFirst . show

instance FromHttpApiData IdeaVoteValue where
    parseUrlPiece = \case
        "yes"     -> Right Yes
        "no"      -> Right No
        _         -> Left "Ill-formed idea vote value: only `yes' or `no' are allowed"

instance HasUriPart UpDown where
    uriPart = fromString . lowerFirst . show

instance FromHttpApiData UpDown where
    parseUrlPiece = \case
        "up"   -> Right Up
        "down" -> Right Down
        _      -> Left "Ill-formed comment vote value: only `up' or `down' are expected)"


-- * location, space, topic

instance HasUILabel IdeaLocation where
    uilabel (IdeaLocationSpace s) = uilabel s
    uilabel (IdeaLocationTopic s (AUID t)) = "Thema #" <> fromString (show t) <> " in " <> uilabel s


-- e.g.: ["10a", "7b", "7a"] ==> ["7a", "7b", "10a"]
instance Ord IdeaSpace where
    compare = compare `on` sortableName
      where
        sortableName :: IdeaSpace -> Maybe [Either String Int]
        sortableName SchoolSpace     = Nothing
        sortableName (ClassSpace cl) = Just . structured . cs . _unClassName . _className $ cl

        structured :: String -> [Either String Int]
        structured = nonDigits
          where
            digits xs = case span isDigit xs of
                            ([], []) -> []
                            ([], zs) -> nonDigits zs
                            (ys, zs) -> Right (read ys) : nonDigits zs
            nonDigits xs = case break isDigit xs of
                            ([], []) -> []
                            ([], zs) -> digits zs
                            (ys, zs) -> Left ys : digits zs

instance HasUILabel IdeaSpace where
    uilabel = \case
        SchoolSpace    -> "Schule"
        ClassSpace c   -> uilabel c

instance HasUriPart IdeaSpace where
    uriPart = fromString . ideaSpaceCode

instance ToHttpApiData IdeaSpace where
    toUrlPiece = cs . ideaSpaceCode

instance FromHttpApiData IdeaSpace where
    parseUrlPiece = parseIdeaSpaceCode'

instance HasUILabel ClassName where
    uilabel = fromString . cs . _unClassName

-- | for the first school year, we can ignore the year.  (after that, we have different options.
-- one would be to only show the year if it is not the current one, or always show it, or either
-- show "current" if applicable or the actual year if it lies in the past.)
instance HasUILabel SchoolClass where
    uilabel = uilabel . _className

instance HasUriPart SchoolClass where
    uriPart = fromString . schoolClassCode

instance FromHttpApiData SchoolClass where
    parseUrlPiece = parseSchoolClassCode'


-- ** delegations

instance HasUILabel Phase where
    uilabel = \case
        PhaseWildIdea{}   -> "Wilde-Ideen-Phase"  -- FIXME: unreachable as of the writing of this
                                                  -- comment, but used for some tests
        PhaseRefinement{} -> "Ausarbeitungsphase"
        PhaseJury         -> "Prüfungsphase"
        PhaseVoting{}     -> "Abstimmungsphase"
        PhaseResult       -> "Ergebnisphase"

instance ToHttpApiData DScope where
    toUrlPiece = (cs :: String -> ST). \case
        (DScopeIdeaSpace space) -> "ideaspace-" <> cs (toUrlPiece space)
        (DScopeTopicId (AUID topicId)) -> "topic-" <> show topicId

instance FromHttpApiData DScope where
    parseUrlPiece scope = case cs scope of
        'i':'d':'e':'a':'s':'p':'a':'c':'e':'-':space -> DScopeIdeaSpace <$> parseUrlPiece (cs space)
        't':'o':'p':'i':'c':'-':topicId -> DScopeTopicId . AUID <$> readEitherCS topicId
        _ -> Left "no parse"

instance HasUriPart DScope where
    uriPart = fromString . cs . toUrlPiece

instance HasUILabel DScopeFull where
    uilabel = \case
        DScopeIdeaSpaceFull is -> "Ideenraum " <> (fromString . cs . uilabelST   $ is)
        DScopeTopicFull t      -> "Thema "     <> (fromString . cs . _topicTitle $ t)
