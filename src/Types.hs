{-# LANGUAGE ConstraintKinds             #-}
{-# LANGUAGE DeriveGeneric               #-}
{-# LANGUAGE FlexibleContexts            #-}
{-# LANGUAGE GeneralizedNewtypeDeriving  #-}
{-# LANGUAGE KindSignatures              #-}
{-# LANGUAGE LambdaCase                  #-}
{-# LANGUAGE OverloadedStrings           #-}
{-# LANGUAGE Rank2Types                  #-}
{-# LANGUAGE ScopedTypeVariables         #-}
{-# LANGUAGE TemplateHaskell             #-}
{-# LANGUAGE TypeFamilies                #-}
{-# LANGUAGE ViewPatterns                #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module Types
    ( module Types
    , readMaybe)
where

import Control.Lens
import Control.Monad
import Data.Binary
import Data.Char
import Data.Map (Map, fromList)
import Data.Proxy (Proxy(Proxy))
import Data.SafeCopy (base, SafeCopy(..), safeGet, safePut, contain, deriveSafeCopy)
import Data.String
import Data.String.Conversions
import Data.Time
import Data.UriPath
import GHC.Generics (Generic)
import Lucid (ToHtml, toHtml, toHtmlRaw)
import Network.Mail.Mime (Address(Address))
import Servant.API (FromHttpApiData(parseUrlPiece), ToHttpApiData(toUrlPiece))
import Text.Read (readMaybe)

import qualified Data.Text as ST
import qualified Data.Csv as CSV
import qualified Generics.SOP as SOP
import qualified Text.Email.Validate as Email

import Test.QuickCheck (Gen, Arbitrary, arbitrary)


-- * a small prelude

-- | A shorter alias for 'mempty'.
nil :: Monoid a => a
nil = mempty

isNil :: (Monoid a, Eq a) => a -> Bool
isNil = (== nil)

readWith :: Read a => Proxy a -> String -> a
readWith Proxy = read

justIf :: a -> Bool -> Maybe a
justIf x b = if b then Just x else Nothing

justIfP :: a -> (a -> Bool) -> Maybe a
justIfP x f = justIf x (f x)

lowerFirst :: String -> String
lowerFirst [] = []
lowerFirst (x:xs) = toLower x : xs

toEnumMay :: forall a. (Enum a, Bounded a) => Int -> Maybe a
toEnumMay i = if i >= 0 && i < fromEnum (maxBound :: a)
    then Just $ toEnum i
    else Nothing

type CSI s t a b = (ConvertibleStrings s a, ConvertibleStrings b t)
type CSI' s a = CSI s s a a

-- An optic for string conversion
-- let p = ("a" :: ST, Just ("b" :: SBS))
-- p ^. _1 . csi :: SBS
-- > "a"
-- p & _1 . csi %~ ('x':)
-- > ("xa", "b")
csi :: CSI s t a b => Iso s t a b
csi = iso cs cs

newtype DurationDays = DurationDays { fromDurationDays :: Int }
  deriving (Eq, Ord, Show, Read, Num, Enum, Real, Integral, Generic)

instance SOP.Generic DurationDays

-- | Percentage values from 0 to 100, used in quorum computations.
type Percent = Int

data Either3 a b c = Left3 a | Middle3 b | Right3 c
  deriving (Eq, Ord, Show, Read, Generic)


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
    }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic Idea

-- | Invariant: for all @IdeaLocationTopic space tid@: idea space of topic with id 'tid' is 'space'.
data IdeaLocation =
      IdeaLocationSpace { _ideaLocationSpace :: IdeaSpace }
    | IdeaLocationTopic { _ideaLocationSpace :: IdeaSpace, _ideaLocationTopicId :: AUID Topic }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic IdeaLocation

-- | Prototype for Idea creation.
data ProtoIdea = ProtoIdea
    { _protoIdeaTitle      :: ST
    , _protoIdeaDesc       :: Document
    , _protoIdeaCategory   :: Maybe Category
    , _protoIdeaLocation   :: IdeaLocation
    }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic ProtoIdea

type instance Proto Idea = ProtoIdea

-- | "Kategorie"
data Category =
    CatRules        -- ^ "Regel"
  | CatEquipment    -- ^ "Ausstattung"
  | CatTeaching     -- ^ "Unterricht"
  | CatTime         -- ^ "Zeit"
  | CatEnvironment  -- ^ "Umgebung"
  deriving (Eq, Ord, Bounded, Enum, Show, Read, Generic)

instance SOP.Generic Category

instance FromHttpApiData Category where
    parseUrlPiece = \case
        "rules"       -> Right CatRules
        "equipment"   -> Right CatEquipment
        "teaching"    -> Right CatTeaching
        "time"        -> Right CatTime
        "environment" -> Right CatEnvironment
        _             -> Left "no parse"

instance ToHttpApiData Category where
    toUrlPiece = \case
        CatRules       -> "rules"
        CatEquipment   -> "equipment"
        CatTeaching    -> "teaching"
        CatTime        -> "time"
        CatEnvironment -> "environment"


-- | FIXME: Is there a better name for 'Like'?  'Star'?  'Endorsement'?  'Interest'?
data IdeaLike = IdeaLike
    { _likeMeta  :: MetaInfo IdeaLike
    }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic IdeaLike

type instance Proto IdeaLike = ()

-- | "Stimme" for "Idee".  As opposed to 'CommentVote', which doesn't have neutral.
data IdeaVote = IdeaVote
    { _ideaVoteMeta  :: MetaInfo IdeaVote
    , _ideaVoteValue :: IdeaVoteValue
    }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic IdeaVote

type instance Proto IdeaVote = IdeaVoteValue

data IdeaVoteValue = Yes | No | Neutral
  deriving (Eq, Ord, Enum, Bounded, Show, Read, Generic)

instance SOP.Generic IdeaVoteValue

data IdeaJuryResult = IdeaJuryResult
    { _ideaJuryResultMeta   :: MetaInfo IdeaJuryResult
    , _ideaJuryResultValue  :: IdeaJuryResultValue
    }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic IdeaJuryResult

data IdeaJuryResultType
    = IdeaNotFeasible
    | IdeaFeasible
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic IdeaJuryResultType

data IdeaJuryResultValue
    = NotFeasible { _ideaResultNotFeasibleReason :: Document }
    | Feasible    { _ideaResultFeasibleReason    :: Maybe Document }
  deriving (Eq, Ord, Show, Read, Generic)

type instance Proto IdeaJuryResult = IdeaJuryResultValue

instance SOP.Generic IdeaJuryResultValue

data IdeaVoteResult = IdeaVoteResult
    { _ideaVoteResultMeta   :: MetaInfo IdeaVoteResult
    , _ideaVoteResultValue  :: IdeaVoteResultValue
    }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic IdeaVoteResult

data IdeaVoteResultValue
    = Winning     { _ideaResultCreatorStatement  :: Maybe Document }
    | EnoughVotes Bool
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic IdeaVoteResultValue

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
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic Comment

type instance Proto Comment = Document

-- | "Stimme" for "Verbesserungsvorschlag"
data CommentVote = CommentVote
    { _commentVoteMeta  :: MetaInfo CommentVote
    , _commentVoteValue :: UpDown
    }
  deriving (Eq, Ord, Show, Read, Generic)

type instance Proto CommentVote = UpDown

instance SOP.Generic CommentVote

data UpDown = Up | Down
  deriving (Eq, Ord, Show, Read, Enum, Bounded, Generic)

instance SOP.Generic UpDown

data CommentContext = CommentContext
    { _parentIdea    :: Idea
    , _parentComment :: Maybe Comment
    }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic CommentContext

-- * idea space, topic, phase

-- | "Ideenraum" is one of "Klasse", "Schule".
data IdeaSpace =
    SchoolSpace
  | ClassSpace { _ideaSpaceSchoolClass :: SchoolClass }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic IdeaSpace

ideaSpaceToSchoolClass :: IdeaSpace -> Maybe SchoolClass
ideaSpaceToSchoolClass (ClassSpace clss) = Just clss
ideaSpaceToSchoolClass _                 = Nothing

-- | "Klasse".  (The school year is necessary as the class name is used for a fresh set of students
-- every school year.)
data SchoolClass = SchoolClass
    { _classSchoolYear :: Int -- ^ e.g. 2015
    , _className       :: ST  -- ^ e.g. "7a"
    }
  deriving (Eq, Ord, Show, Read, Generic)

-- | FIXME: needs to be gone by the end of school year 2016!
theOnlySchoolYearHack :: Int
theOnlySchoolYearHack = 2016

schoolClass :: Int -> ST -> SchoolClass
schoolClass = SchoolClass

-- | A 'Topic' is created inside an 'IdeaSpace'.  It is used as a container for a "wild idea" that
-- has reached a quorum, plus more ideas that the moderator decides belong here.  'Topic's have
-- 'Phase's.  All 'Idea's in a 'Topic' must have the same 'IdeaSpace' as the 'Topic'.
data Topic = Topic
    { _topicMeta      :: MetaInfo Topic
    , _topicTitle     :: ST
    , _topicDesc      :: Document
    , _topicImage     :: URL
    , _topicIdeaSpace :: IdeaSpace
    , _topicPhase     :: Phase
    }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic Topic

data ProtoTopic = ProtoTopic
    { _protoTopicTitle     :: ST
    , _protoTopicDesc      :: Document
    , _protoTopicImage     :: URL
    , _protoTopicIdeaSpace :: IdeaSpace
    , _protoTopicIdeas     :: [AUID Idea]
    , _protoTopicRefinDays :: Timestamp
    }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic ProtoTopic

type instance Proto Topic = ProtoTopic

-- Edit topic description and add ideas to topic.
data EditTopicData = EditTopicData
    { _editTopicTitle    :: ST
    , _editTopicDesc     :: Document
    , _editTopicAddIdeas :: [AUID Idea]
    }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic EditTopicData

-- | Topic phases.  (Phase 1.: "wild ideas", is where 'Topic's are born, and we don't need a
-- constructor for that here.)
data Phase =
    PhaseRefinement Timestamp  -- ^ 2. "Ausarbeitungsphase"
  | PhaseJury                  -- ^ 3. "Prüfungsphase"
  | PhaseVoting     Timestamp  -- ^ 4. "Abstimmungsphase"
  | PhaseResult                -- ^ 5. "Ergebnisphase"
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic Phase

phaseName :: Phase -> ST
phaseName = \case
    PhaseRefinement _ -> "Ausarbeitungsphase"
    PhaseJury         -> "Prüfungsphase"
    PhaseVoting     _ -> "Abstimmungsphase"
    PhaseResult       -> "Ergebnisphase"

followsPhase :: Phase -> Phase -> Bool
followsPhase PhaseJury       (PhaseRefinement _) = True
followsPhase (PhaseVoting _) PhaseJury           = True
followsPhase PhaseResult     (PhaseVoting _)     = True
followsPhase _               _                   = False


-- * user

data User = User
    { _userMeta      :: MetaInfo User
    , _userLogin     :: UserLogin
    , _userFirstName :: UserFirstName
    , _userLastName  :: UserLastName
    , _userAvatar    :: Maybe URL
    , _userRole      :: Role
    , _userPassword  :: UserPass
    , _userEmail     :: Maybe EmailAddress
    }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic User

newtype UserLogin     = UserLogin     { _fromUserLogin     :: ST }
  deriving (Eq, Ord, Show, Read, IsString, Monoid, Generic, FromHttpApiData)

newtype UserFirstName = UserFirstName { _fromUserFirstName :: ST }
  deriving (Eq, Ord, Show, Read, IsString, Monoid, Generic, FromHttpApiData)

newtype UserLastName  = UserLastName  { _fromUserLastName  :: ST }
  deriving (Eq, Ord, Show, Read, IsString, Monoid, Generic, FromHttpApiData)

type instance Proto User = ProtoUser

data ProtoUser = ProtoUser
    { _protoUserLogin     :: Maybe UserLogin
    , _protoUserFirstName :: UserFirstName
    , _protoUserLastName  :: UserLastName
    , _protoUserRole      :: Role
    , _protoUserPassword  :: UserPass
    , _protoUserEmail     :: Maybe EmailAddress
    }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic ProtoUser

-- | Note that all roles except 'Student' and 'ClassGuest' have the same access to all IdeaSpaces.
-- (Rationale: e.g. teachers have trust each other and can cover for each other.)
data Role =
    Student    { _studentSchoolClass :: SchoolClass }
  | ClassGuest { _guestSchoolClass   :: SchoolClass } -- ^ e.g., parents
  | SchoolGuest  -- ^ e.g., researchers
  | Moderator
  | Principal
  | Admin
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic Role

data UserPass =
    UserPassInitial   { _userPassInitial   :: ST }
  | UserPassEncrypted { _userPassEncrypted :: SBS } -- FIXME: use "Crypto.Scrypt.EncryptedPass"
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic UserPass

newtype EmailAddress = InternalEmailAddress { internalEmailAddress :: Email.EmailAddress }
    deriving (Eq, Ord, Show, Read, Generic)

instance CSV.FromField EmailAddress where
    parseField f = either fail (pure . InternalEmailAddress) . Email.validate =<< CSV.parseField f

instance Binary EmailAddress where
    put = put . Email.toByteString . internalEmailAddress
    get = maybe mzero (pure . InternalEmailAddress) . Email.emailAddress =<< get

instance SafeCopy EmailAddress where
    kind = base
    getCopy = contain $ maybe mzero (pure . InternalEmailAddress) . Email.emailAddress =<< safeGet
    putCopy = contain . safePut . Email.toByteString . internalEmailAddress

-- | "Beauftragung"
data Delegation = Delegation
    { _delegationMeta    :: MetaInfo Delegation
    , _delegationContext :: DelegationContext
    , _delegationFrom    :: AUID User
    , _delegationTo      :: AUID User
    }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic Delegation

type instance Proto Delegation = ProtoDelegation

-- | "Beauftragung"
data ProtoDelegation = ProtoDelegation
    { _protoDelegationContext :: DelegationContext
    , _protoDelegationFrom    :: AUID User
    , _protoDelegationTo      :: AUID User
    }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic ProtoDelegation

data DelegationContext =
    DlgCtxIdeaSpace { _delCtxIdeaSpace :: IdeaSpace  }
  | DlgCtxTopicId   { _delCtxTopicId   :: AUID Topic }
  | DlgCtxIdeaId    { _delCtxIdeaId    :: AUID Idea  }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic DelegationContext

data DelegationNetwork = DelegationNetwork
    { _networkUsers         :: [User]
    , _networkDelegations   :: [Delegation]
    }
  deriving (Eq, Show, Read, Generic)

instance SOP.Generic DelegationNetwork

-- | Elaboration and Voting phase durations
-- FIXME: elaboration and refinement are the same thing.  pick one term!
data Durations = Durations
    { _elaborationPhase :: DurationDays
    , _votingPhase      :: DurationDays
    }
  deriving (Eq, Show, Read, Generic)

instance SOP.Generic Durations

data Quorums = Quorums
    { _schoolQuorumPercentage :: Int
    , _classQuorumPercentage  :: Int -- (there is only one quorum for all classes, see gh#318)
    }
  deriving (Eq, Show, Read, Generic)

instance SOP.Generic Quorums

data Settings = Settings
    { _durations :: Durations
    , _quorums   :: Quorums
    }
  deriving (Eq, Show, Read, Generic)

instance SOP.Generic Settings

defaultSettings :: Settings
defaultSettings = Settings
    { _durations = Durations { _elaborationPhase = 21, _votingPhase = 21 }
    , _quorums   = Quorums   { _schoolQuorumPercentage = 30, _classQuorumPercentage = 30 }
    }

-- * aula-specific helper types

-- | Aula Unique ID for reference in the database.  This is unique for one concrete phantom type
-- only and will probably be generated by sql `serial` type.
newtype AUID a = AUID Integer
  deriving (Eq, Ord, Show, Read, Generic, FromHttpApiData, Enum, Real, Num, Integral)

instance SOP.Generic (AUID a)

type family   IdOf a
type instance IdOf User             = AUID User
type instance IdOf Idea             = AUID Idea
type instance IdOf Topic            = AUID Topic
type instance IdOf Delegation       = AUID Delegation
type instance IdOf Comment          = AUID Comment
-- ^ A more precise identifier would be:
--      IdOf Comment = (AUID Idea, NonEmpty (AUID Comment))
-- This would be the full path from AulaData down to the comment
-- which could be a reply to reply...
type instance IdOf CommentVote      = AUID User
type instance IdOf IdeaVote         = AUID User
type instance IdOf IdeaLike         = AUID User
-- ^ If we were to have more precise comment identifiers these 3 could
-- become: (IdOf Comment, AUID User)
type instance IdOf IdeaVoteResult   = AUID IdeaVoteResult
type instance IdOf IdeaJuryResult   = AUID IdeaJuryResult

type AMap a = Map (IdOf a) a

type Users        = AMap User
type Ideas        = AMap Idea
type Topics       = AMap Topic
type Delegations  = AMap Delegation
type Comments     = AMap Comment
type CommentVotes = AMap CommentVote
type IdeaVotes    = AMap IdeaVote
type IdeaLikes    = AMap IdeaLike

instance HasUriPart (AUID a) where
    uriPart (AUID s) = fromString . show $ s

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
data GMetaInfo a id = MetaInfo
    { _metaId              :: id
    , _metaCreatedBy       :: AUID User
    , _metaCreatedByLogin  :: UserLogin
    , _metaCreatedByAvatar :: Maybe URL
    , _metaCreatedAt       :: Timestamp
    , _metaChangedBy       :: AUID User
    , _metaChangedAt       :: Timestamp
    }
  deriving (Eq, Ord, Show, Read, Generic)

instance SOP.Generic id => SOP.Generic (GMetaInfo a id)

type MetaInfo a = GMetaInfo a (IdOf a)

-- | Markdown content.
newtype Document = Markdown { fromMarkdown :: ST }
  deriving (Eq, Ord, Show, Read, Generic)

instance ToHtml Document where
    toHtml    = toHtml    . fromMarkdown
    toHtmlRaw = toHtmlRaw . fromMarkdown


-- * general-purpose types

-- | Use this for storing URLs in the aula state.  Unlike 'UriPath' is serializable, has equality,
-- and unlike "Frontend.Path", it is flexible enough to contain internal and external uris.
-- (FUTUREWORK: the `uri-bytestring` package could be nice here, but it may require a few orphans or
-- a newtype to prevent them; see also: #31.)
type URL = ST

newtype Timestamp = Timestamp { fromTimestamp :: UTCTime }
  deriving (Eq, Ord, Generic)

instance Binary Timestamp where
    put = put . renderTimestamp
    get = get >>= maybe mzero return . parseTimestamp

instance Show Timestamp where
    show = renderTimestamp

instance Read Timestamp where
    readsPrec _ s = case splitAt timestampFormatLength $ dropWhile isSpace s of
        (parseTimestamp -> Just t, r) -> [(t, r)]
        _                             -> error $ "Read Timestamp: " <> show s

parseTimestamp :: String -> Maybe Timestamp
parseTimestamp = fmap Timestamp . parseTimeM True defaultTimeLocale timestampFormat

renderTimestamp :: Timestamp -> String
renderTimestamp = formatTime defaultTimeLocale timestampFormat . fromTimestamp

timestampFormat :: String
timestampFormat = "%F_%T_%q"

timestampFormatLength :: Int
timestampFormatLength = length ("1864-04-13_13:01:33_846177415049" :: String)


-- | FIXME: should either go to the test suite or go away completely.
class Monad m => GenArbitrary m where
    genGen :: Gen a -> m a

-- | FIXME: should either go to the test suite or go away completely.
genArbitrary :: (GenArbitrary m, Arbitrary a) => m a
genArbitrary = genGen arbitrary


-- * admin pages

-- FIXME: rename this.  it's not just about permissions, but also about links and menu items.
-- (also, it's weird that we are not using PermissionContext as a capture in the routing table in
-- Frontend any more, but still in Frontend.Path to construct safe uris.  Not a real problem, but
-- perhaps we can resolve this assymetry somehow if we think about it more?)
data PermissionContext
    = PermUserView
    | PermUserCreate
    | PermClassView
    | PermClassCreate
  deriving (Eq, Show, Read, Generic)

instance SOP.Generic PermissionContext

pContextToUriStr :: PermissionContext -> ST
pContextToUriStr PermUserView    = "perm-user-view"
pContextToUriStr PermUserCreate  = "perm-user-create"
pContextToUriStr PermClassView   = "perm-class-view"
pContextToUriStr PermClassCreate = "perm-class-create"

uriStrToPContext :: ST -> Maybe PermissionContext
uriStrToPContext "perm-user-view"    = Just PermUserView
uriStrToPContext "perm-user-create"  = Just PermUserCreate
uriStrToPContext "perm-class-view"   = Just PermClassView
uriStrToPContext "perm-class-create" = Just PermClassCreate
uriStrToPContext _                   = Nothing

instance FromHttpApiData PermissionContext where
    parseUrlPiece x =
        maybe (Left "No parse")
              Right
              $ uriStrToPContext (cs x)

instance HasUriPart PermissionContext where
    uriPart = uriPart . pContextToUriStr


-- * boilerplate: binary, lens (alpha order), SafeCopy

instance Binary (AUID a)
instance Binary Category
instance Binary Comment
instance Binary CommentVote
instance Binary Delegation
instance Binary DelegationContext
instance Binary Document
instance Binary UserPass
instance Binary Role
instance Binary Idea
instance Binary IdeaLocation
instance Binary IdeaLike
instance Binary IdeaJuryResult
instance Binary IdeaJuryResultValue
instance Binary IdeaVoteResult
instance Binary IdeaVoteResultValue
instance Binary IdeaSpace
instance Binary IdeaVote
instance Binary IdeaVoteValue
instance Binary id => Binary (GMetaInfo a id)
instance Binary Phase
instance Binary SchoolClass
instance Binary Topic
instance Binary UpDown
instance Binary User
instance Binary UserLogin
instance Binary UserFirstName
instance Binary UserLastName
instance Binary DurationDays
instance Binary Durations
instance Binary Quorums
instance Binary Settings

makePrisms ''AUID
makePrisms ''IdeaLocation
makePrisms ''Category
makePrisms ''Document
makePrisms ''IdeaVoteValue
makePrisms ''IdeaJuryResultValue
makePrisms ''IdeaVoteResultValue
makePrisms ''UpDown
makePrisms ''IdeaSpace
makePrisms ''Phase
makePrisms ''Role
makePrisms ''UserPass
makePrisms ''DelegationContext
makePrisms ''PermissionContext
makePrisms ''EmailAddress
makePrisms ''UserLastName
makePrisms ''UserFirstName
makePrisms ''UserLogin

makeLenses ''Category
makeLenses ''Comment
makeLenses ''CommentContext
makeLenses ''CommentVote
makeLenses ''Delegation
makeLenses ''DelegationContext
makeLenses ''DelegationNetwork
makeLenses ''Document
makeLenses ''Durations
makeLenses ''EditTopicData
makeLenses ''Idea
makeLenses ''IdeaLocation
makeLenses ''IdeaLike
makeLenses ''IdeaJuryResult
makeLenses ''IdeaVoteResult
makeLenses ''IdeaSpace
makeLenses ''IdeaVote
makeLenses ''GMetaInfo
makeLenses ''Phase
makeLenses ''ProtoDelegation
makeLenses ''ProtoIdea
makeLenses ''ProtoTopic
makeLenses ''ProtoUser
makeLenses ''Role
makeLenses ''SchoolClass
makeLenses ''Settings
makeLenses ''Topic
makeLenses ''UpDown
makeLenses ''User
makeLenses ''EmailAddress
makeLenses ''UserLogin
makeLenses ''UserFirstName
makeLenses ''UserLastName
makeLenses ''UserPass
makeLenses ''Quorums

deriveSafeCopy 0 'base ''AUID
deriveSafeCopy 0 'base ''Category
deriveSafeCopy 0 'base ''Comment
deriveSafeCopy 0 'base ''CommentVote
deriveSafeCopy 0 'base ''Delegation
deriveSafeCopy 0 'base ''DelegationContext
-- deriveSafeCopy 0 'base ''DelegationNetwork
deriveSafeCopy 0 'base ''Document
deriveSafeCopy 0 'base ''DurationDays
deriveSafeCopy 0 'base ''Durations
deriveSafeCopy 0 'base ''EditTopicData
deriveSafeCopy 0 'base ''Idea
deriveSafeCopy 0 'base ''IdeaLike
deriveSafeCopy 0 'base ''IdeaLocation
-- deriveSafeCopy 0 'base ''IdeaLike
deriveSafeCopy 0 'base ''IdeaJuryResult
deriveSafeCopy 0 'base ''IdeaVoteResult
deriveSafeCopy 0 'base ''IdeaJuryResultValue
deriveSafeCopy 0 'base ''IdeaVoteResultValue
deriveSafeCopy 0 'base ''IdeaSpace
deriveSafeCopy 0 'base ''IdeaVote
deriveSafeCopy 0 'base ''IdeaVoteValue
deriveSafeCopy 0 'base ''GMetaInfo
deriveSafeCopy 0 'base ''Phase
deriveSafeCopy 0 'base ''ProtoDelegation
deriveSafeCopy 0 'base ''ProtoIdea
deriveSafeCopy 0 'base ''ProtoTopic
deriveSafeCopy 0 'base ''ProtoUser
deriveSafeCopy 0 'base ''Role
deriveSafeCopy 0 'base ''SchoolClass
deriveSafeCopy 0 'base ''Settings
deriveSafeCopy 0 'base ''Timestamp
deriveSafeCopy 0 'base ''Topic
deriveSafeCopy 0 'base ''UpDown
deriveSafeCopy 0 'base ''User
deriveSafeCopy 0 'base ''UserLogin
deriveSafeCopy 0 'base ''UserFirstName
deriveSafeCopy 0 'base ''UserLastName
deriveSafeCopy 0 'base ''UserPass
deriveSafeCopy 0 'base ''Quorums

class Ord (IdOf a) => HasMetaInfo a where
    metaInfo        :: Lens' a (MetaInfo a)
    _Id             :: Lens' a (IdOf a)
    _Id             = metaInfo . metaId
    createdBy       :: Lens' a (AUID User)
    createdBy       = metaInfo . metaCreatedBy
    createdByLogin  :: Lens' a UserLogin
    createdByLogin  = metaInfo . metaCreatedByLogin
    createdByAvatar :: Lens' a (Maybe URL)
    createdByAvatar = metaInfo . metaCreatedByAvatar
    createdAt       :: Lens' a Timestamp
    createdAt       = metaInfo . metaCreatedAt
    changedBy       :: Lens' a (AUID User)
    changedBy       = metaInfo . metaChangedBy
    changedAt       :: Lens' a Timestamp
    changedAt       = metaInfo . metaChangedAt

instance HasMetaInfo Comment where metaInfo = commentMeta
instance HasMetaInfo CommentVote where metaInfo = commentVoteMeta
instance HasMetaInfo Delegation where metaInfo = delegationMeta
instance HasMetaInfo Idea where metaInfo = ideaMeta
instance HasMetaInfo IdeaLike where metaInfo = likeMeta
instance HasMetaInfo IdeaJuryResult where metaInfo = ideaJuryResultMeta
instance HasMetaInfo IdeaVoteResult where metaInfo = ideaVoteResultMeta
instance HasMetaInfo IdeaVote where metaInfo = ideaVoteMeta
instance HasMetaInfo Topic where metaInfo = topicMeta
instance HasMetaInfo User where metaInfo = userMeta

{- Examples:
    e :: EmailAddress
    s :: ST
    s = emailAddress # e

    s :: ST
    s = "foo@example.com"
    e :: Maybe EmailAddress
    e = s ^? emailAddress


  These more limited type signatures are also valid:
    emailAddress :: Prism' ST  EmailAddress
    emailAddress :: Prism' LBS EmailAddress
-}
emailAddress :: (CSI s t SBS SBS) => Prism s t EmailAddress EmailAddress
emailAddress = csi . prism' Email.toByteString Email.emailAddress . from _InternalEmailAddress

unsafeEmailAddress :: (ConvertibleStrings local SBS, ConvertibleStrings domain SBS) =>
                      local -> domain -> EmailAddress
unsafeEmailAddress local domain = InternalEmailAddress $ Email.unsafeEmailAddress (cs local) (cs domain)

{- Example:
    u :: User
    s :: Maybe ST
    s = u ^? userEmailAddress
-}
userEmailAddress :: CSI' s SBS => Fold User s
userEmailAddress = userEmail . _Just . re emailAddress

userFullName :: User -> ST
userFullName u = u ^. userFirstName . _UserFirstName <> " " <> u ^. userLastName . _UserLastName

userAddress :: User -> Maybe Address
userAddress u = u ^? userEmailAddress . to (Address . Just $ userFullName u)

notFeasibleIdea :: Idea -> Bool
notFeasibleIdea = has $ ideaJuryResult . _Just . ideaJuryResultValue . _NotFeasible

winningIdea :: Idea -> Bool
winningIdea = has $ ideaVoteResult . _Just . ideaVoteResultValue . _Winning

instance HasUriPart IdeaSpace where
    uriPart = fromString . showIdeaSpace

instance HasUriPart SchoolClass where
    uriPart = fromString . showSchoolClass

showIdeaSpace :: IdeaSpace -> String
showIdeaSpace SchoolSpace    = "school"
showIdeaSpace (ClassSpace c) = showSchoolClass c

showSchoolClass :: SchoolClass -> String
showSchoolClass c = show (c ^. classSchoolYear) <> "-" <> cs (c ^. className)

showIdeaSpaceCategory :: IsString s => IdeaSpace -> s
showIdeaSpaceCategory SchoolSpace    = "school"
showIdeaSpaceCategory (ClassSpace _) = "class"

parseIdeaSpace :: (IsString err, Monoid err) => ST -> Either err IdeaSpace
parseIdeaSpace s
    | s == "school" = Right SchoolSpace
    | otherwise     = ClassSpace <$> parseSchoolClass s

parseSchoolClass :: (IsString err, Monoid err) => ST -> Either err SchoolClass
parseSchoolClass s = case ST.splitOn "-" s of
    [year, name] -> (`schoolClass` name) <$> readYear year
    _:_:_:_      -> err "Too many parts (two parts expected)"
    _            -> err "Too few parts (two parts expected)"
  where
    err msg = Left $ "Ill-formed school class: " <> msg
    readYear = maybe (err "Year should be only digits") Right . readMaybe . cs

instance FromHttpApiData IdeaSpace where
    parseUrlPiece = parseIdeaSpace

instance FromHttpApiData SchoolClass where
    parseUrlPiece = parseSchoolClass

instance FromHttpApiData IdeaVoteValue where
    parseUrlPiece = \case
        "yes"     -> Right Yes
        "no"      -> Right No
        "neutral" -> Right Neutral
        _         -> Left "Ill-formed idea vote value: only `yes', `no' or `neutral' are allowed"

instance HasUriPart IdeaVoteValue where
    uriPart = fromString . lowerFirst . show

instance FromHttpApiData IdeaJuryResultType where
    parseUrlPiece = \case
      "good" -> Right IdeaNotFeasible
      "bad"  -> Right IdeaFeasible
      _      -> Left "Ill-formed idea vote value: only `good' or `bad' are allowed"

instance ToHttpApiData IdeaJuryResultType where
    toUrlPiece = \case
      IdeaNotFeasible -> "good"
      IdeaFeasible    -> "bad"

instance HasUriPart IdeaJuryResultType where
    uriPart = fromString . cs . toUrlPiece

instance HasUriPart UpDown where
    uriPart = fromString . lowerFirst . show

instance FromHttpApiData UpDown where
    parseUrlPiece = \case
        "up"   -> Right Up
        "down" -> Right Down
        _      -> Left "Ill-formed comment vote value: only `up' or `down' are expected)"

ideaTopicId :: Traversal' Idea (AUID Topic)
ideaTopicId = ideaLocation . ideaLocationTopicId

ideaLocationMaybeTopicId :: Lens' IdeaLocation (Maybe (AUID Topic))
ideaLocationMaybeTopicId f = \case
    IdeaLocationSpace spc     -> mk spc <$> f Nothing
    IdeaLocationTopic spc tid -> mk spc <$> f (Just tid)
  where
    mk spc = \case
        Nothing  -> IdeaLocationSpace spc
        Just tid -> IdeaLocationTopic spc tid

ideaMaybeTopicId :: Lens' Idea (Maybe (AUID Topic))
ideaMaybeTopicId = ideaLocation . ideaLocationMaybeTopicId

isWild :: IdeaLocation -> Bool
isWild (IdeaLocationSpace _)   = True
isWild (IdeaLocationTopic _ _) = False

-- | Construct an 'IdeaLocation' from a 'Topic'
topicIdeaLocation :: Topic -> IdeaLocation
topicIdeaLocation = IdeaLocationTopic <$> (^. topicIdeaSpace) <*> (^. _Id)

-- | german role name
roleLabel :: IsString s => Role -> s
roleLabel (Student _)    = "Schüler"
roleLabel (ClassGuest _) = "Gast (Klasse)"
roleLabel SchoolGuest    = "Gast (Schule)"
roleLabel Moderator      = "Moderator"
roleLabel Principal      = "Direktor"
roleLabel Admin          = "Administrator"

aMapFromList :: HasMetaInfo a => [a] -> AMap a
aMapFromList = fromList . map (\x -> (x ^. _Id, x))

foldComment :: Fold Comment Comment
foldComment = cosmosOf (commentReplies . each)

foldComments :: Fold Comments Comment
foldComments = each . foldComment

commentsCount :: Getter Comments Int
commentsCount = to $ lengthOf foldComments

countEq :: (Foldable f, Eq value) => value -> Lens' vote value -> f vote -> Int
countEq v l = lengthOf $ folded . filtered ((== v) . view l)

countIdeaVotes :: IdeaVoteValue -> IdeaVotes -> Int
countIdeaVotes v = countEq v ideaVoteValue

countCommentVotes :: UpDown -> CommentVotes -> Int
countCommentVotes v = countEq v commentVoteValue


-- * event log

data EventLog = EventLog IdeaSpace [(Timestamp, EventLogItem)]
  deriving (Eq, Ord, Show, Read)

data EventLogItem =
    EventLogUserCreates           User (Either3 Topic Idea Comment)
  | EventLogUserEdits             User (Either3 Topic Idea Comment)
  | EventLogUserMarksIdeaFeasible User IdeaJuryResultValue Idea
  | EventLogUserVotesOnIdea       User Idea IdeaVote
  | EventLogUserVotesOnComment    User Idea CommentVote
  | EventLogUserDelegates         User Delegation User
  | EventLogTopicMovesFromTo      Phase Phase EventTriggeredBy
  | EventLogIdeaMovesToTopic      User Idea Topic
  | EventLogIdeaWins              User Idea
  deriving (Eq, Ord, Show, Read)

data EventTriggeredBy =
    EventTriggeredBy User
  | EventTriggeredByTimeout
  | EventTriggeredByAllIdeasMarked
  deriving (Eq, Ord, Show, Read)
