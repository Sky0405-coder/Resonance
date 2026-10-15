// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get settingsPlayback => 'Playback';

  @override
  String get commonProductName => 'Resonance';

  @override
  String get errorInvalidInput => 'Invalid input';

  @override
  String get errorServerUnreachable => 'Server unreachable';

  @override
  String errorHttpStatus(String statusCode) {
    return 'Error $statusCode';
  }

  @override
  String get catalogSingle => 'Single';

  @override
  String get catalogCompilation => 'Compilation';

  @override
  String get commonAlbum => 'Album';

  @override
  String get commonUnknown => 'Unknown';

  @override
  String get playerMusicLoadError => 'The music couldn\'t be loaded. Please try again.';

  @override
  String get playerAudiobookLoadError => 'The audiobook couldn\'t be loaded. Please try again.';

  @override
  String playerBookPart(int part, int total) {
    return 'Part $part of $total';
  }

  @override
  String get navHome => 'Home';

  @override
  String get navSearch => 'Search';

  @override
  String get navLibrary => 'Your Library';

  @override
  String get navAudiobooks => 'Audiobooks';

  @override
  String get navAdmin => 'Admin';

  @override
  String get navDownloads => 'Downloads';

  @override
  String get adminDashboard => 'Admin Dashboard';

  @override
  String get libraryCreatePlaylist => 'Create playlist';

  @override
  String get libraryNewPlaylist => 'New playlist';

  @override
  String get commonName => 'Name';

  @override
  String get libraryLikedSongs => 'Liked Songs';

  @override
  String get commonPlaylist => 'Playlist';

  @override
  String libraryPlaylistBy(String name) {
    return 'Playlist • $name';
  }

  @override
  String get navSettings => 'Settings';

  @override
  String get searchHint => 'What do you want to listen to?';

  @override
  String searchNoLibraryResults(String query) {
    return 'No results for “$query” in your library.';
  }

  @override
  String get commonSongsTitle => 'Songs';

  @override
  String get commonArtist => 'Artist';

  @override
  String get commonAlbums => 'Albums';

  @override
  String get libraryAllArtists => 'All artists';

  @override
  String get libraryTitle => 'Your Library';

  @override
  String get libraryPlaylists => 'Playlists';

  @override
  String get librarySavedAlbums => 'Saved albums';

  @override
  String get libraryAllAlbums => 'All albums';

  @override
  String get libraryLoadingSongs => '… songs';

  @override
  String get libraryNoAlbums => 'No albums';

  @override
  String get librarySaveAlbumsHint => 'Save albums with ⊕ to see them here.';

  @override
  String commonDiscNumber(int number) {
    return 'CD $number';
  }

  @override
  String get libraryRemoveAlbum => 'Remove from library';

  @override
  String get librarySaveAlbum => 'Save to library';

  @override
  String get playerAddToPlaylist => 'Add to playlist';

  @override
  String get editorCorrectAlbum => 'Edit album metadata';

  @override
  String get editorMatchAlbum => 'Match album';

  @override
  String get editorChangeCover => 'Change cover';

  @override
  String artistLibraryAlbums(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count albums in your library',
      one: '$count album in your library',
    );
    return '$_temp0';
  }

  @override
  String get artistPopular => 'Popular';

  @override
  String get artistDiscography => 'Discography';

  @override
  String get libraryPublicPlaylist => 'Public playlist';

  @override
  String get libraryRenamePlaylist => 'Rename playlist';

  @override
  String get commonRename => 'Rename';

  @override
  String get libraryMakePrivate => 'Make private';

  @override
  String get librarySharePlaylist => 'Share with all users';

  @override
  String get commonDelete => 'Delete';

  @override
  String get libraryEmptyPlaylist => 'No songs yet. Add some using a song\'s ⋯ menu.';

  @override
  String get libraryRemoveFromPlaylist => 'Remove from this playlist';

  @override
  String get homeGreetingNight => 'Good night';

  @override
  String get homeGreetingMorning => 'Good morning';

  @override
  String get homeGreetingAfternoon => 'Good afternoon';

  @override
  String get homeGreetingEvening => 'Good evening';

  @override
  String get homeRecentlyPlayed => 'Recently played';

  @override
  String get homeYourPlaylists => 'Your playlists';

  @override
  String get homeRecentlyAdded => 'New in your library';

  @override
  String get homeEmptyLibrary => 'Your library is still empty.\nAn admin can start a library scan in the dashboard.';

  @override
  String get playerNothingPlaying => 'Nothing playing right now';

  @override
  String get playerQueue => 'Queue';

  @override
  String get audiobooksBook => 'Audiobook';

  @override
  String get playerGoToAudiobook => 'Go to audiobook';

  @override
  String get audiobooksChapters => 'Chapters';

  @override
  String get playerEmptyQueue => 'The queue is empty';

  @override
  String get playerNowPlaying => 'Now playing';

  @override
  String get playerNextUp => 'Next up';

  @override
  String get playerRemoveFromQueue => 'Remove from queue';

  @override
  String get settingsAccount => 'Account';

  @override
  String get settingsAdministratorSuffix => ' • Administrator';

  @override
  String get settingsDisplayName => 'Display name';

  @override
  String get settingsChangePassword => 'Change password';

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsAccentColor => 'Accent color';

  @override
  String get settingsCustomColor => 'Custom color';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonApply => 'Apply';

  @override
  String get settingsNormalizeVolume => 'Normalize volume';

  @override
  String get settingsNormalizeVolumeHint => 'Uses ReplayGain to keep songs at a similar volume';

  @override
  String get settingsSignedInDevices => 'Signed-in devices';

  @override
  String get settingsUnknownDevice => 'Unknown device';

  @override
  String get settingsCurrentDeviceSuffix => ' (this device)';

  @override
  String settingsLastActive(String date) {
    return 'Last active: $date';
  }

  @override
  String get commonSignOut => 'Log out';

  @override
  String get settingsCurrentPassword => 'Current password';

  @override
  String get settingsNewPassword => 'New password';

  @override
  String get commonChange => 'Change';

  @override
  String get settingsPasswordChanged => 'Password changed';

  @override
  String get catalogDiscoverMore => 'Discover more';

  @override
  String get catalogDownloadHint => 'Download music here that isn\'t in your library yet.';

  @override
  String get catalogNoResults => 'Nothing found in the catalog either.';

  @override
  String get catalogAllInLibrary => 'All in your library';

  @override
  String catalogLibraryCount(int count, int total) {
    return '$count of $total in your library';
  }

  @override
  String get catalogDownloadAlbum => 'Download album';

  @override
  String get catalogDownloadMissingSong => 'Download missing song';

  @override
  String catalogDownloadMissingSongs(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Download $count missing songs',
      one: 'Download $count missing song',
    );
    return '$_temp0';
  }

  @override
  String get catalogOpenInLibrary => 'Open in library';

  @override
  String get catalogEps => 'EPs';

  @override
  String get catalogSingles => 'Singles';

  @override
  String catalogArtistReleases(int count, int inLibrary) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count releases • $inLibrary in your library',
      one: '$count release • $inLibrary in your library',
    );
    return '$_temp0';
  }

  @override
  String get downloadsMine => 'Mine';

  @override
  String get downloadsAllUsers => 'All users';

  @override
  String get downloadsOpen => 'Open';

  @override
  String get downloadsCompleted => 'Completed';

  @override
  String get downloadsEmptyActive => 'No active downloads.\nSearch for music and tap ⤓.';

  @override
  String get downloadsEmptyCompleted => 'Nothing downloaded yet.';

  @override
  String get commonSong => 'Song';

  @override
  String downloadsRequestedBySuffix(String name) {
    return 'by $name';
  }

  @override
  String get downloadsReject => 'Reject';

  @override
  String get downloadsApprove => 'Approve';

  @override
  String get downloadsRejectRequest => 'Reject request';

  @override
  String get downloadsReasonOptional => 'Reason (optional)';

  @override
  String get downloadsDownload => 'Download';

  @override
  String downloadsProgress(String status, int done, int total, String failed) {
    return '$status • $done/$total done$failed';
  }

  @override
  String downloadsFailedSuffix(int count) {
    return ' • $count failed';
  }

  @override
  String downloadsRequestedBy(String name) {
    return 'Requested by $name';
  }

  @override
  String downloadsReason(String reason) {
    return 'Reason: $reason';
  }

  @override
  String get downloadsRetryFailed => 'Retry failed downloads';

  @override
  String get downloadsDeleteEntry => 'Delete entry';

  @override
  String get catalogYouTubeMusic => 'YouTube Music';

  @override
  String get downloadsTorrent => 'Torrent';

  @override
  String get downloadsSearchingTorrent => 'Searching for a torrent …';

  @override
  String downloadsTorrentProgress(String name, int progress) {
    return 'Torrent: $name ($progress %)';
  }

  @override
  String get downloadsImportingTorrent => 'Importing torrent …';

  @override
  String downloadsTorrentName(String name) {
    return 'Torrent: $name';
  }

  @override
  String downloadsTorrentFallback(String error) {
    return 'No torrent – downloading from YouTube Music$error';
  }

  @override
  String commonDurationHoursMinutes(int hours, int minutes) {
    return '$hours hr $minutes min';
  }

  @override
  String commonDurationMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String get audiobooksFinished => 'Finished';

  @override
  String audiobooksTimeRemaining(String duration) {
    return '$duration left';
  }

  @override
  String get audiobooksNotConfigured => 'Audiobooks aren\'t set up on this server.';

  @override
  String get audiobooksLoginTitle => 'Connect to Audiobookshelf';

  @override
  String audiobooksLoginHint(String address) {
    return 'Log in with your Audiobookshelf account$address. Your listening progress stays in sync across all Audiobookshelf apps.';
  }

  @override
  String get authUsername => 'Username';

  @override
  String get authPassword => 'Password';

  @override
  String get authSignIn => 'Log in';

  @override
  String get audiobooksNoLibrary => 'No audiobook library found';

  @override
  String audiobooksSignOutUser(String name) {
    return 'Log out ($name)';
  }

  @override
  String get audiobooksSearchHint => 'Search by title, author, or series';

  @override
  String get audiobooksContinueListening => 'Continue listening';

  @override
  String get audiobooksAllBooks => 'All audiobooks';

  @override
  String get commonNothingFound => 'Nothing found';

  @override
  String audiobooksNarrator(String name) {
    return 'narrated by $name';
  }

  @override
  String get audiobooksStartOver => 'Start from the beginning';

  @override
  String get audiobooksMarkUnfinished => 'Mark as unfinished';

  @override
  String get audiobooksMarkFinished => 'Mark as finished';

  @override
  String authCheckAddress(String error) {
    return '$error\nIs the address correct?';
  }

  @override
  String get authConnectTitle => 'Connect to server';

  @override
  String get authServerAddress => 'Server address';

  @override
  String get authConnect => 'Connect';

  @override
  String get commonRetry => 'Try again';

  @override
  String get authOtherServer => 'Other server';

  @override
  String authSignInTo(String name) {
    return 'Log in to $name';
  }

  @override
  String get authCreateAccount => 'Create account';

  @override
  String authServer(String address) {
    return 'Server: $address';
  }

  @override
  String get authPasswordsMismatch => 'Passwords don\'t match';

  @override
  String get authInvalidInvite => 'Invalid invitation';

  @override
  String get authInvalidInviteHint =>
      'This invite link has already been used or has expired. Please ask an admin for a new link.';

  @override
  String get authBackToLogin => 'Back to login';

  @override
  String get authWelcomeAdmin => 'Welcome! Create an admin account';

  @override
  String get authFirstAccountHint => 'The first account on this server automatically becomes an administrator.';

  @override
  String get authPasswordMinimum => 'Password (min. 8 characters)';

  @override
  String get authRepeatPassword => 'Repeat password';

  @override
  String get authRegister => 'Sign up';

  @override
  String get authAlreadyHaveAccount => 'I already have an account';

  @override
  String catalogAwaitingApproval(String title) {
    return '“$title” is waiting for admin approval';
  }

  @override
  String catalogAlreadyInLibrary(String title) {
    return '“$title” is already in your library';
  }

  @override
  String catalogDownloadingTitle(String title) {
    return '“$title” is being downloaded';
  }

  @override
  String get catalogInYourLibrary => 'In your library';

  @override
  String get catalogRequested => 'Requested';

  @override
  String get catalogDownload => 'Download';

  @override
  String get catalogInLibrary => 'In library';

  @override
  String get downloadsStatusPendingApproval => 'Waiting for approval';

  @override
  String get downloadsStatusRunning => 'Running';

  @override
  String get commonDone => 'Done';

  @override
  String get downloadsStatusPartial => 'Partially complete';

  @override
  String get downloadsStatusFailed => 'Failed';

  @override
  String get downloadsStatusRejected => 'Rejected';

  @override
  String get downloadsStatusCancelled => 'Cancelled';

  @override
  String get downloadsStatusQueued => 'Queued';

  @override
  String get downloadsStatusSearching => 'Finding a source …';

  @override
  String get downloadsStatusDownloading => 'Downloading';

  @override
  String get downloadsStatusProcessing => 'Tagging …';

  @override
  String get downloadsStatusExisting => 'Already exists';

  @override
  String get playerShuffle => 'Shuffle';

  @override
  String get playerRemoveLiked => 'Remove from Liked Songs';

  @override
  String get playerAddLiked => 'Add to Liked Songs';

  @override
  String get playerPlayNext => 'Play next';

  @override
  String get playerAddToQueue => 'Add to queue';

  @override
  String get playerGoToAlbum => 'Go to album';

  @override
  String get playerGoToArtist => 'Go to artist';

  @override
  String get editorCorrectMetadata => 'Edit metadata';

  @override
  String libraryAddedToPlaylist(String name) {
    return 'Added to “$name”';
  }

  @override
  String get commonSave => 'Save';

  @override
  String get playerSkipBack => 'Back 30 seconds';

  @override
  String get playerSkipForward => 'Forward 30 seconds';

  @override
  String get playerPrevious => 'Previous';

  @override
  String get playerNext => 'Next';

  @override
  String get playerRepeat => 'Repeat';

  @override
  String get playerSpeed => 'Speed';

  @override
  String get playerSleepTimer => 'Sleep timer';

  @override
  String playerSleepTimerTime(String time) {
    return 'Sleep timer: pauses at $time';
  }

  @override
  String playerTimerMinutes(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes minutes',
      one: '$minutes minute',
    );
    return '$_temp0';
  }

  @override
  String get playerDisableTimer => 'Turn off timer';

  @override
  String get playerFullscreen => 'Fullscreen';

  @override
  String commonDurationMinutesSeconds(int minutes, int seconds) {
    return '$minutes min $seconds sec';
  }

  @override
  String get updateAllowInstall => 'Please allow Resonance to install apps in Android settings.';

  @override
  String updateFailedCode(String code) {
    return 'Update failed ($code). Please try again.';
  }

  @override
  String updateFailedMessage(String error) {
    return 'Update failed: $error';
  }

  @override
  String get updateInProgress => 'Updating app';

  @override
  String get updateDownloadStarting => 'Starting download …';

  @override
  String updateDownloadProgress(int percent) {
    return 'Download $percent %';
  }

  @override
  String get commonClose => 'Close';

  @override
  String updateAvailableTitle(String version) {
    return 'New app version $version available';
  }

  @override
  String get updateInstall => 'Install';

  @override
  String updateInstalledVersion(String version) {
    return 'App version $version';
  }

  @override
  String updateAvailableVersion(String version) {
    return 'Version $version is available';
  }

  @override
  String get updateCurrent => 'Up to date';

  @override
  String get updateAction => 'Update';

  @override
  String get updateCheck => 'Check for updates';

  @override
  String get updateAlreadyCurrent => 'The app is up to date';

  @override
  String get adminImportCleanupTitle => 'Clean up library?';

  @override
  String get adminImportCleanupHint =>
      'All songs in the library will be identified by audio fingerprint, retagged, given cover art, and renamed to “Artist/Album (Year)/No - Title”. The files will be modified directly.\n\nLikes, playlists, and history will be preserved. This takes several hours for large libraries.';

  @override
  String get adminImportCleanupConfirm => 'Clean up';

  @override
  String get adminImportFolder => 'Import folder';

  @override
  String adminImportPendingFiles(int count, String mode) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count audio files waiting • Mode: $mode',
      one: '$count audio file waiting • Mode: $mode',
    );
    return '$_temp0';
  }

  @override
  String get adminImportCopyHint => 'Copy (originals stay unchanged)';

  @override
  String get adminImportMove => 'Move';

  @override
  String get adminImportAcoustIdHint =>
      'No AcoustID key configured – songs will only be identified using their existing tags. Get a free key at acoustid.org/new-application and enter it under “Server”.';

  @override
  String get adminImportStart => 'Start import';

  @override
  String get adminImportCleanup => 'Clean up library';

  @override
  String get adminImportHistory => 'History';

  @override
  String get adminImportEmptyHistory => 'No imports yet.';

  @override
  String get adminImportWaiting => 'Waiting';

  @override
  String adminImportBatchTitle(String mode) {
    return 'Import ($mode)';
  }

  @override
  String adminImportFileProgress(int count, int total) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$count of $total files',
      one: '$count of $total file',
    );
    return '$_temp0';
  }

  @override
  String get adminImportIdentified => 'Identified';

  @override
  String get adminImportImported => 'Imported';

  @override
  String get adminImportDuplicates => 'Duplicates';

  @override
  String get adminImportUnidentified => 'Unidentified';

  @override
  String get adminImportErrors => 'Errors';

  @override
  String get adminImportMethodAlbumFingerprint => 'Identified by fingerprint (whole album)';

  @override
  String get adminImportMethodTrackFingerprint => 'Identified by fingerprint (single song)';

  @override
  String get adminImportMethodTags => 'Identified using existing tags (catalog)';

  @override
  String get adminImportMethodUnidentified => 'Unidentified – existing tags kept';

  @override
  String get adminTabOverview => 'Overview';

  @override
  String get adminTabUsers => 'Users';

  @override
  String get adminTabInvites => 'Invitations';

  @override
  String get adminTabImport => 'Import';

  @override
  String get adminTabReview => 'Review';

  @override
  String get adminTabServer => 'Server';

  @override
  String get adminStorage => 'Storage';

  @override
  String get adminPlaytime => 'Playtime';

  @override
  String commonDurationHours(String hours) {
    return '$hours hr';
  }

  @override
  String get adminScanHint =>
      'A quick scan reads only new and changed files. A full scan rereads all tags and cover art.';

  @override
  String get adminQuickScan => 'Quick scan';

  @override
  String get adminFullScan => 'Full scan';

  @override
  String get adminJobs => 'Jobs';

  @override
  String get adminNoJobs => 'No jobs yet';

  @override
  String get adminLibraryScan => 'Library scan';

  @override
  String get adminUserYouSuffix => ' (you)';

  @override
  String get adminUserDisabledSuffix => ' • disabled';

  @override
  String adminUserLastSeenSuffix(String date) {
    return ' • last seen $date';
  }

  @override
  String adminNewPasswordFor(String name) {
    return 'New password for $name';
  }

  @override
  String get adminPasswordSet => 'Password set, all devices logged out';

  @override
  String adminDeleteUserTitle(String name) {
    return 'Delete $name?';
  }

  @override
  String get adminDeleteUserHint => 'Playlists and history will also be deleted.';

  @override
  String get adminRemoveAdmin => 'Remove admin rights';

  @override
  String get adminMakeAdmin => 'Make admin';

  @override
  String get adminEnableUser => 'Enable';

  @override
  String get adminDisableUser => 'Disable';

  @override
  String get adminResetPassword => 'Reset password';

  @override
  String get adminPasswordMinimum => 'Min. 8 characters';

  @override
  String get adminCreateInviteTitle => 'Create invite link';

  @override
  String get adminInviteNote => 'Note (e.g. who it\'s for)';

  @override
  String get adminInviteValidity => 'Valid for';

  @override
  String get adminInviteOneDay => '1 day';

  @override
  String get adminInviteThreeDays => '3 days';

  @override
  String get adminInviteSevenDays => '7 days';

  @override
  String get adminInviteThirtyDays => '30 days';

  @override
  String get adminInviteUnlimited => 'Unlimited';

  @override
  String get adminInviteAsAdmin => 'Register as admin';

  @override
  String get commonCreate => 'Create';

  @override
  String get adminInviteLink => 'Invite link';

  @override
  String get adminInviteLinkHint => 'This link can be used exactly once. It is only shown now.';

  @override
  String get adminLinkCopied => 'Link copied';

  @override
  String get commonCopy => 'Copy';

  @override
  String get adminNewInvite => 'New link';

  @override
  String get adminNoInvites => 'No invitations yet.\nCreate a link to invite someone.';

  @override
  String get adminInvitation => 'Invitation';

  @override
  String adminInviteUsed(String name, String date) {
    return 'Used by $name on $date';
  }

  @override
  String get adminInviteExpired => 'Expired';

  @override
  String adminInviteOpen(String expiry, String role) {
    return 'Open • $expiry$role';
  }

  @override
  String get adminInviteNoExpiry => 'never expires';

  @override
  String adminInviteExpires(String date) {
    return 'valid until $date';
  }

  @override
  String get adminInviteAdminSuffix => ' • Admin';

  @override
  String get adminServerName => 'Server name';

  @override
  String get adminRegistration => 'Registration';

  @override
  String get adminRegistrationInviteOnly => 'Invite link only';

  @override
  String get adminRegistrationInviteHint => 'Admins create single-use links (recommended)';

  @override
  String get adminRegistrationPublic => 'Public registration';

  @override
  String get adminRegistrationPublicHint => 'Anyone who can reach the server can create an account';

  @override
  String get adminLibraryImport => 'Library & Import';

  @override
  String get adminAcoustIdKey => 'AcoustID key';

  @override
  String get adminAcoustIdNotSet => 'Not set – get a free key at acoustid.org/new-application';

  @override
  String get adminConfigured => 'Set';

  @override
  String get adminAcoustIdHint => 'For identification using audio fingerprints';

  @override
  String get adminMoveImportedFiles => 'Move imported files';

  @override
  String get adminMoveImportedFilesHint => 'The import folder is emptied afterwards';

  @override
  String get adminCopyImportedFiles => 'Copy imported files';

  @override
  String get adminCopyImportedFilesHint => 'Originals stay unchanged in the import folder';

  @override
  String get adminImportUnidentifiedFiles => 'Import unidentified files anyway';

  @override
  String get adminImportUnidentifiedFilesHint => 'Using their existing tags; otherwise they stay in the import folder';

  @override
  String get adminAutoImport => 'Automatically import the import folder';

  @override
  String get adminAutoImportHint => 'Checks for new files every 5 minutes (only in “Move” mode)';

  @override
  String get adminSongRadio => 'Song radio';

  @override
  String get adminRadioAutoDownload => 'Automatically download missing songs';

  @override
  String get adminRadioAutoDownloadHint =>
      'Similar songs that aren\'t in the library yet are added to the download queue';

  @override
  String get adminRadioTemporary => 'Radio downloads are temporary';

  @override
  String adminRadioTemporaryHint(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'Deleted after $days days unless someone likes them or adds them to a playlist',
      one: 'Deleted after $days day unless someone likes them or adds them to a playlist',
    );
    return '$_temp0';
  }

  @override
  String get adminRadioRetention => 'Temporary song retention (days)';

  @override
  String get adminEnableAudiobookshelf => 'Connect Audiobookshelf';

  @override
  String get adminEnableAudiobookshelfHint =>
      'Shows the “Audiobooks” tab. Each user logs in with their own Audiobookshelf account.';

  @override
  String get adminAudiobookshelfAddress => 'Audiobookshelf address';

  @override
  String get adminAudiobookshelfAddressHint => 'e.g. https://audio.example.com – also used by external apps';

  @override
  String get adminAlbumTorrents => 'Torrents for albums';

  @override
  String get adminAlbumTorrentsHint =>
      'Searches for albums through Prowlarr (public trackers) first and downloads them with qBittorrent over the VPN. Anything missing comes from YouTube Music.';

  @override
  String get adminProwlarrApiKey => 'Prowlarr API key';

  @override
  String get adminProwlarrApiKeyHint => 'Prowlarr → Settings → General → API Key';

  @override
  String get adminQbittorrentUsername => 'qBittorrent username';

  @override
  String get adminQbittorrentPassword => 'qBittorrent password';

  @override
  String get adminMinimumSeeders => 'Minimum seeders';

  @override
  String get adminTorrentTimeout => 'Give up after … minutes without progress';

  @override
  String get adminYouTubeSource => 'YouTube Music as a source';

  @override
  String get adminYouTubeSourceHint => 'Downloads songs from YouTube Music via yt-dlp (Opus, approx. 130–160 kbit/s)';

  @override
  String get adminQualityUpgrades => 'Quality upgrades';

  @override
  String get adminQualityUpgradesHint => 'Replace low-quality songs (e.g. from YouTube) with FLAC/MP3 320 later';

  @override
  String get adminAutoApprove => 'Automatically approve requests';

  @override
  String get adminAutoApproveHint => 'Otherwise an admin must approve users\' requests';

  @override
  String get adminDailyLimit => 'Daily limit per user';

  @override
  String adminDailyLimitHint(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Max. $count automatic downloads per day',
      one: 'Max. $count automatic download per day',
    );
    return '$_temp0';
  }

  @override
  String get adminDownloadsPerDay => 'Downloads per user per day';

  @override
  String get adminNotConfigured => 'Not set';

  @override
  String get adminTestConnection => 'Test connection';

  @override
  String get adminProwlarr => 'Prowlarr';

  @override
  String get adminQbittorrent => 'qBittorrent';

  @override
  String editorSavedTrack(String title, String artist, String album) {
    return 'Saved: $title – $artist ($album)';
  }

  @override
  String editorBitrate(int bitrate) {
    return '$bitrate kbit/s';
  }

  @override
  String get editorTabSearch => 'Search';

  @override
  String get editorTabFingerprint => 'Fingerprint';

  @override
  String get editorTabEdit => 'Edit';

  @override
  String get editorSearchTrackHint => 'Artist and title';

  @override
  String get editorChooseTrackHint => 'Tap the correct song to apply its tags, cover art, and filename.';

  @override
  String get editorFingerprintSearching => 'Matching audio fingerprint …';

  @override
  String get editorFingerprintUnknown => 'AcoustID doesn\'t recognize this recording. Try “Search” or “Edit”.';

  @override
  String get editorUnknownTitle => 'Unknown title';

  @override
  String editorFingerprintScore(int percent) {
    return '   $percent % match';
  }

  @override
  String get editorAutoSelectAlbum => 'Choose original album automatically';

  @override
  String get editorUnknownAlbum => 'Unknown album';

  @override
  String editorTrackNumberWithTotal(int number, String total) {
    return 'No. $number$total';
  }

  @override
  String editorTrackTotalSuffix(int total) {
    return ' of $total';
  }

  @override
  String get editorNumbersOnly => 'Please enter numbers only for year, track number, and CD';

  @override
  String get editorNoChanges => 'No changes';

  @override
  String get editorTitle => 'Title';

  @override
  String get editorSwapTitleArtist => 'Swap title and artist';

  @override
  String get editorAlbumArtist => 'Album artist';

  @override
  String get editorYear => 'Year';

  @override
  String get editorTrackNumber => 'No.';

  @override
  String get editorGenre => 'Genre';

  @override
  String get editorManualHint =>
      'Empty fields stay unchanged. The file is then renamed to “Album Artist/Album (Year)/No - Title”.';

  @override
  String editorMatchedSongs(int count, int total) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$count of $total songs matched',
      one: '$count of $total song matched',
    );
    return '$_temp0';
  }

  @override
  String get editorUnmatchedSongs => 'Unmatched (unchanged):';

  @override
  String get editorSearchAlbumHint => 'Artist and album or MusicBrainz link';

  @override
  String editorMatchAlbumHint(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'The $count songs on this album are matched to the chosen release by title, position, and duration. Songs that don\'t match stay unchanged.',
      one:
          'The $count song on this album is matched to the chosen release by title, position, and duration. Songs that don\'t match stay unchanged.',
    );
    return '$_temp0';
  }

  @override
  String get editorUseMusicBrainzRelease => 'Use MusicBrainz release';

  @override
  String get editorRetagging => 'Retagging songs …';

  @override
  String get editorCoverSaved => 'Cover saved';

  @override
  String get editorCoverSuggestionsHint =>
      'Suggestions from MusicBrainz and Deezer. The cover is embedded in all songs on the album.';

  @override
  String get editorUploadImage => 'Upload image';

  @override
  String get editorNoCoverSuggestions => 'No suggestions found';

  @override
  String get editorNoCover => 'No cover';

  @override
  String editorAlbumCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count albums', one: '$count album');
    return '$_temp0';
  }

  @override
  String get editorLoadMore => 'Load more';

  @override
  String get editorAllDone => 'All done 🎉';

  @override
  String get commonOk => 'OK';

  @override
  String get editorDisc => 'CD';

  @override
  String get catalogEp => 'EP';

  @override
  String get adminImportCopyMode => 'copy';

  @override
  String get adminImportMoveMode => 'move';

  @override
  String get adminLibrary => 'Library';

  @override
  String commonSongs(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count songs', one: '1 song');
    return '$_temp0';
  }

  @override
  String get commonArtists => 'Artists';

  @override
  String get adminUserRole => 'User';

  @override
  String get authServerAddressExample => 'music.example.com';

  @override
  String get spotifyTitle => 'Import from Spotify';

  @override
  String get spotifyNotConfigured =>
      'Spotify isn\'t set up on this server yet. An admin can do that in the Admin Dashboard under “Server”.';

  @override
  String get spotifyConnectHint =>
      'Connect your Spotify account to bring your Liked Songs and your own playlists into Resonance.';

  @override
  String get spotifyConnect => 'Connect Spotify';

  @override
  String get spotifyWaiting => 'Log in to Spotify in the window that opened, then come back here.';

  @override
  String spotifyConnectedAs(String name) {
    return 'Connected as $name';
  }

  @override
  String get spotifyDisconnect => 'Disconnect';

  @override
  String get spotifyLikedSongs => 'Liked Songs';

  @override
  String spotifyLikedHint(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count songs', one: '1 song');
    return '$_temp0 · will be liked in Resonance';
  }

  @override
  String get spotifyPlaylistsHeading => 'Your playlists';

  @override
  String get spotifyPlaylistsNote => 'Spotify only shares playlists you own or collaborate on.';

  @override
  String spotifyPlaylistSubtitle(int count, String owner) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count songs', one: '1 song');
    return '$_temp0 · $owner';
  }

  @override
  String get spotifyAlreadyImported => 'already imported – will be synced';

  @override
  String get spotifyDownloadMissing => 'Download missing songs';

  @override
  String get spotifyDownloadMissingHint =>
      'Songs that aren\'t in the library yet are requested and added automatically once downloaded.';

  @override
  String get spotifyStart => 'Start import';

  @override
  String get spotifyNothingSelected => 'Select Liked Songs or at least one playlist.';

  @override
  String get spotifyStarted => 'Import started';

  @override
  String get spotifyHistory => 'Previous imports';

  @override
  String get spotifyStatusQueued => 'Queued';

  @override
  String get spotifyStatusRunning => 'Running';

  @override
  String get spotifyStatusDone => 'Done';

  @override
  String get spotifyStatusFailed => 'Failed';

  @override
  String spotifyImportCounts(int matched, int total, int missing, int requested) {
    return '$matched of $total found · $missing missing · $requested requested';
  }

  @override
  String get spotifyShowMissing => 'Show missing';

  @override
  String get spotifyMissingTitle => 'Not in the library';

  @override
  String get adminSpotifyGroup => 'Spotify import';

  @override
  String get adminSpotifyClientId => 'Spotify Client ID';

  @override
  String get adminSpotifyClientSecret => 'Spotify Client Secret';

  @override
  String adminSpotifyHint(String uri) {
    return 'developer.spotify.com/dashboard → create an app, Redirect URI: $uri';
  }

  @override
  String get audiobooksViewLibrary => 'Library';

  @override
  String get audiobooksViewSeries => 'Series';

  @override
  String get audiobooksViewAuthors => 'Authors';

  @override
  String get audiobooksViewNarrators => 'Narrators';

  @override
  String audiobooksBookCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count audiobooks', one: '1 audiobook');
    return '$_temp0';
  }

  @override
  String get albumFindMissing => 'Find missing songs';

  @override
  String get adminDeleteSong => 'Delete song';

  @override
  String get adminDeleteAlbum => 'Delete album';

  @override
  String adminDeleteSongConfirm(String title) {
    return '\"$title\" will be permanently deleted from the server, including the file.';
  }

  @override
  String adminDeleteAlbumConfirm(String title) {
    return 'The album \"$title\" and all its songs will be permanently deleted from the server, including the files.';
  }

  @override
  String get adminDeleted => 'Deleted';

  @override
  String get libraryShareWithUsers => 'Share with specific users';

  @override
  String get libraryNoOtherUsers => 'There are no other users yet.';

  @override
  String librarySharedWith(String names) {
    return 'Shared with $names';
  }

  @override
  String albumMissingTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs not in your library',
      one: '1 song not in your library',
    );
    return '$_temp0';
  }

  @override
  String get radioStartSong => 'Go to song radio';

  @override
  String get radioStartAlbum => 'Go to album radio';

  @override
  String get radioKind => 'Radio';

  @override
  String get radioKeep => 'Keep as playlist';

  @override
  String radioDownloading(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count missing songs are being downloaded and will then be added to the radio',
      one: '1 missing song is being downloaded and will then be added to the radio',
    );
    return '$_temp0';
  }

  @override
  String get libraryRadios => 'Radios';

  @override
  String get adminRadioMaxDownloads => 'Max. downloads per radio start';

  @override
  String get adminRadioPlaylistRetention => 'Keep radios (days since last use, 0 = forever)';

  @override
  String get offlineBanner => 'Offline – downloaded music only';

  @override
  String get offlineEmptyHint => 'Download albums and playlists to listen offline.';

  @override
  String get offlineDownloaded => 'Downloaded';

  @override
  String get offlineDownload => 'Download';

  @override
  String get offlineRemoveTitle => 'Remove download?';

  @override
  String get offlineQuality => 'Download quality';

  @override
  String get offlineQualityNormal => 'Normal (Opus 160 kbit/s)';

  @override
  String get offlineQualityHigh => 'High (Opus 256 kbit/s)';

  @override
  String get offlineQualityOriginal => 'Original (lossless, uses a lot of storage)';

  @override
  String get offlineWifiOnly => 'Download over Wi-Fi only';

  @override
  String get offlineStorage => 'Storage used';

  @override
  String offlineStorageUsed(String size, int count) {
    return '$size • $count songs';
  }

  @override
  String offlineMegabytes(String value) {
    return '$value MB';
  }

  @override
  String offlineGigabytes(String value) {
    return '$value GB';
  }

  @override
  String offlineDownloading(int count) {
    return '$count songs downloading';
  }

  @override
  String offlineProgress(int done, int total) {
    return '$done of $total downloaded';
  }

  @override
  String get offlineClearAll => 'Delete all downloads';

  @override
  String get offlineClearConfirm => 'Delete all downloads?';

  @override
  String get mixKind => 'Mix';

  @override
  String get mixSave => 'Save as playlist';

  @override
  String get homeMadeForYou => 'Made for you';

  @override
  String get homeGenreMixes => 'Your genres';
}
