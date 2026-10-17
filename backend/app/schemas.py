import re
import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.models import Role

HEX_COLOR = re.compile(r"^#[0-9A-Fa-f]{6}$")


class ORM(BaseModel):
    model_config = ConfigDict(from_attributes=True)


# --- auth / users -----------------------------------------------------------


class UserOut(ORM):
    id: uuid.UUID
    username: str
    display_name: str
    role: Role
    accent_color: str
    is_disabled: bool
    has_subsonic_password: bool
    created_at: datetime
    last_seen_at: datetime | None


class AuthStatus(BaseModel):
    server_name: str
    setup_required: bool
    registration_mode: str


class RegisterIn(BaseModel):
    username: str = Field(min_length=2, max_length=64, pattern=r"^[A-Za-z0-9_.-]+$")
    password: str = Field(min_length=8, max_length=256)
    display_name: str | None = Field(None, max_length=128)
    invite: str | None = None
    device_name: str | None = Field(None, max_length=128)


class LoginIn(BaseModel):
    username: str
    password: str
    device_name: str | None = Field(None, max_length=128)


class TokenOut(BaseModel):
    token: str
    user: UserOut


class ProfilePatch(BaseModel):
    display_name: str | None = Field(None, min_length=1, max_length=128)
    accent_color: str | None = None
    current_password: str | None = None
    new_password: str | None = Field(None, min_length=8, max_length=256)

    @field_validator("accent_color")
    @classmethod
    def _hex(cls, v: str | None) -> str | None:
        if v is not None and not HEX_COLOR.match(v):
            raise ValueError("accent_color must look like #RRGGBB")
        return v.upper() if v else v


class SessionOut(ORM):
    id: uuid.UUID
    device_name: str | None
    created_at: datetime
    last_used_at: datetime
    current: bool = False


# --- admin ------------------------------------------------------------------


class InviteIn(BaseModel):
    note: str | None = Field(None, max_length=256)
    role: Role = Role.user
    # None = never expires
    expires_in_hours: int | None = Field(72, ge=1, le=24 * 365)


class InviteOut(ORM):
    id: uuid.UUID
    note: str | None
    role: Role
    created_at: datetime
    expires_at: datetime | None
    used_at: datetime | None
    used_by_username: str | None = None


class InviteCreated(InviteOut):
    token: str


class UserAdminPatch(BaseModel):
    role: Role | None = None
    is_disabled: bool | None = None
    new_password: str | None = Field(None, min_length=8, max_length=256)


class JobOut(ORM):
    id: uuid.UUID
    kind: str
    status: str
    progress: float
    message: str | None
    created_at: datetime
    finished_at: datetime | None


class DuplicateTrackOut(ORM):
    id: uuid.UUID
    title: str
    path: str
    codec: str | None
    bitrate: int | None
    size: int
    duration: float
    keep: bool


class DuplicateGroupOut(BaseModel):
    album_id: uuid.UUID
    album_title: str
    artist_name: str
    tracks: list[DuplicateTrackOut]


class DuplicateMergeIn(BaseModel):
    keep_ids: list[uuid.UUID] = Field(max_length=5000)


# --- library ----------------------------------------------------------------


class ArtistRef(ORM):
    id: uuid.UUID
    name: str


class AlbumRef(ORM):
    id: uuid.UUID
    title: str


class LyricLine(BaseModel):
    time_ms: int | None
    text: str


class LyricsOut(BaseModel):
    synced: bool
    instrumental: bool
    source: str | None
    lines: list[LyricLine]


class TrackOut(ORM):
    id: uuid.UUID
    title: str
    artist: ArtistRef
    artist_credit: str
    album: AlbumRef
    track_no: int | None
    disc_no: int | None
    duration: float
    codec: str | None
    bitrate: int | None
    replaygain_track_gain: float | None
    replaygain_album_gain: float | None
    liked: bool = False


class AlbumOut(ORM):
    id: uuid.UUID
    title: str
    artist: ArtistRef
    year: int | None
    genre: str | None
    has_cover: bool = False
    track_count: int = 0


class AlbumDetail(AlbumOut):
    duration: float = 0
    saved: bool = False
    tracks: list[TrackOut] = []


class ArtistOut(ORM):
    id: uuid.UUID
    name: str
    album_count: int = 0
    cover_album_id: uuid.UUID | None = None


class ArtistDetail(ArtistOut):
    albums: list[AlbumOut] = []
    top_tracks: list[TrackOut] = []


class SearchResult(BaseModel):
    artists: list[ArtistOut]
    albums: list[AlbumOut]
    tracks: list[TrackOut]


class Page[T](BaseModel):
    items: list[T]
    total: int
    offset: int
    limit: int


# --- playlists --------------------------------------------------------------


class PlaylistIn(BaseModel):
    name: str = Field(min_length=1, max_length=256)
    description: str | None = Field(None, max_length=4000)
    is_public: bool = False


class PlaylistPatch(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=256)
    description: str | None = Field(None, max_length=4000)
    is_public: bool | None = None


class PlaylistSharesIn(BaseModel):
    user_ids: list[uuid.UUID] = Field(max_length=100)


class PlaylistOut(ORM):
    id: uuid.UUID
    name: str
    description: str | None
    is_public: bool
    kind: str = "user"
    mix_key: str | None = None
    owner: ArtistRef  # {id, name} of the owning user
    shared_with: list[ArtistRef] = []
    track_count: int = 0
    duration: float = 0
    # Up to 4 album ids for a mosaic cover.
    cover_album_ids: list[uuid.UUID] = []
    cover_key: str | None = None
    updated_at: datetime


class RadioIn(BaseModel):
    seed_type: Literal["track", "album"]
    id: uuid.UUID


class RadioOut(BaseModel):
    playlist: PlaylistOut
    requested: int


class MixesOut(BaseModel):
    made_for_you: list[PlaylistOut]
    genres: list[PlaylistOut]
    discover: PlaylistOut | None


class PlaylistEntryOut(BaseModel):
    entry_id: uuid.UUID
    added_at: datetime
    track: TrackOut


class PlaylistDetail(PlaylistOut):
    entries: list[PlaylistEntryOut] = []
    editable: bool = False


class AddTracksIn(BaseModel):
    track_ids: list[uuid.UUID] = Field(min_length=1, max_length=1000)
    # Insert before this entry; append when omitted.
    before_entry_id: uuid.UUID | None = None


class MoveEntryIn(BaseModel):
    entry_id: uuid.UUID
    before_entry_id: uuid.UUID | None = None


class PlayEventIn(BaseModel):
    track_id: uuid.UUID
    seconds_played: float = Field(ge=0)
    context: str | None = Field(None, max_length=128)


class HomeOut(BaseModel):
    recently_played: list[AlbumOut]
    recently_added: list[AlbumOut]
    playlists: list[PlaylistOut]
    most_played: list[TrackOut]


# --- catalog / downloads ----------------------------------------------------


class CatalogArtist(BaseModel):
    id: str
    name: str
    picture_url: str | None
    library_id: uuid.UUID | None = None


class CatalogAlbum(BaseModel):
    id: str
    title: str
    artist: str
    artist_id: str | None
    record_type: str | None
    year: int | None
    cover_url: str | None
    cover_big_url: str | None
    library_id: uuid.UUID | None = None


class CatalogTrack(BaseModel):
    id: str
    title: str
    artist: str
    artist_id: str | None
    album: str | None
    album_id: str | None
    cover_url: str | None
    duration: float | None
    isrc: str | None = None
    preview_url: str | None
    disc_no: int | None = None
    track_no: int | None = None
    library_id: uuid.UUID | None = None


class MissingTracksOut(BaseModel):
    catalog_id: str
    tracks: list[CatalogTrack]


class CatalogArtistDetail(BaseModel):
    artist: CatalogArtist
    top_tracks: list[CatalogTrack]
    albums: list[CatalogAlbum]


class CatalogAlbumDetail(CatalogAlbum):
    label: str | None
    genres: list[str]
    tracks: list[CatalogTrack]


class CatalogSearchOut(BaseModel):
    artists: list[CatalogArtist]
    albums: list[CatalogAlbum]
    tracks: list[CatalogTrack]


class UserRef(ORM):
    id: uuid.UUID
    username: str


class DownloadItemOut(ORM):
    id: uuid.UUID
    position: int
    title: str
    artist: str
    duration: float | None
    status: str
    progress: float
    source: str | None
    error: str | None
    track_id: uuid.UUID | None


class DownloadRequestOut(ORM):
    id: uuid.UUID
    kind: str
    mb_id: str | None
    catalog_id: str | None
    replace_track_id: uuid.UUID | None
    title: str
    artist: str
    cover_url: str | None
    status: str
    is_temporary: bool
    note: str | None
    torrent_status: str | None
    torrent_name: str | None
    torrent_progress: float
    torrent_error: str | None
    created_at: datetime
    updated_at: datetime
    user: UserRef
    progress: float
    item_count: int
    done_count: int
    failed_count: int


class DownloadRequestDetail(DownloadRequestOut):
    items: list[DownloadItemOut]


class RequestIn(BaseModel):
    kind: Literal["track", "album"]
    id: str = Field(min_length=1, max_length=20, pattern=r"^[0-9]+$")
    temporary: bool = False


class RedownloadIn(BaseModel):
    youtube_url: str | None = Field(None, max_length=500)


class RejectIn(BaseModel):
    note: str | None = Field(None, max_length=500)


class DownloadSummary(BaseModel):
    active: int
    queued: int
    failed: int
    pending_approval: int


# --- imports ---------------------------------------------------------------


class ImportBatchIn(BaseModel):
    kind: Literal["import", "cleanup"]


class ImportBatchOut(ORM):
    id: uuid.UUID
    kind: str
    mode: str
    status: str
    total: int
    processed: int
    identified: int
    imported: int
    duplicates: int
    unidentified: int
    failed: int
    message: str | None
    created_at: datetime
    finished_at: datetime | None
    progress: float = 0


class ImportFileOut(ORM):
    id: uuid.UUID
    path: str
    status: str
    method: str | None
    acoustid_score: float | None
    target: str | None
    error: str | None
    title: str | None = None
    artist: str | None = None
    album: str | None = None


# --- metadata editor --------------------------------------------------------


class ManualMetaIn(BaseModel):
    title: str | None = Field(None, min_length=1, max_length=512)
    artist: str | None = Field(None, min_length=1, max_length=512)
    album: str | None = Field(None, min_length=1, max_length=512)
    album_artist: str | None = Field(None, min_length=1, max_length=512)
    year: int | None = Field(None, ge=1000, le=2100)
    track_no: int | None = Field(None, ge=1, le=999)
    disc_no: int | None = Field(None, ge=1, le=99)
    genre: str | None = Field(None, max_length=256)


class TrackFileOut(BaseModel):
    path: str
    title: str | None
    artist: str | None
    album: str | None
    album_artist: str | None
    year: int | None
    track_no: int | None
    disc_no: int | None
    genre: str | None
    duration: float
    codec: str | None
    bitrate: int | None
    mb_recording_id: str | None
    mb_release_id: str | None
    query: str


class FingerprintReleaseOut(BaseModel):
    release_id: str
    album: str | None
    year: int | None
    disc_no: int | None
    track_no: int | None
    release_tracks: int | None


class FingerprintMatchOut(BaseModel):
    recording_id: str
    title: str | None
    artist: str | None
    score: float
    releases: list[FingerprintReleaseOut]


class TrackMatchIn(BaseModel):
    source: Literal["deezer", "musicbrainz", "manual"]
    deezer_id: str | None = None
    recording_id: str | None = None
    release_id: str | None = None
    meta: ManualMetaIn | None = None


class AlbumMatchIn(BaseModel):
    source: Literal["deezer", "musicbrainz"]
    id: str


class AlbumMatchOut(BaseModel):
    album: AlbumOut | None
    matched: int
    unmatched: list[TrackOut]


class CoverOptionOut(BaseModel):
    url: str
    source: Literal["musicbrainz", "deezer"]
    label: str


class ReviewTrackOut(TrackOut):
    path: str
