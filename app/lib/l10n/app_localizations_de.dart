// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get settingsPlayback => 'Wiedergabe';

  @override
  String get commonProductName => 'Resonance';

  @override
  String get errorInvalidInput => 'Ungültige Eingabe';

  @override
  String get errorServerUnreachable => 'Server nicht erreichbar';

  @override
  String errorHttpStatus(String statusCode) {
    return 'Fehler $statusCode';
  }

  @override
  String get catalogSingle => 'Single';

  @override
  String get catalogCompilation => 'Compilation';

  @override
  String get commonAlbum => 'Album';

  @override
  String get commonUnknown => 'Unbekannt';

  @override
  String get playerMusicLoadError => 'Die Musik konnte nicht geladen werden. Bitte erneut versuchen.';

  @override
  String get playerAudiobookLoadError => 'Das Hörbuch konnte nicht geladen werden. Bitte erneut versuchen.';

  @override
  String playerBookPart(int part, int total) {
    return 'Teil $part von $total';
  }

  @override
  String get navHome => 'Start';

  @override
  String get navSearch => 'Suche';

  @override
  String get navLibrary => 'Bibliothek';

  @override
  String get navAudiobooks => 'Hörbücher';

  @override
  String get navAdmin => 'Admin';

  @override
  String get navDownloads => 'Downloads';

  @override
  String get adminDashboard => 'Admin-Dashboard';

  @override
  String get libraryCreatePlaylist => 'Playlist erstellen';

  @override
  String get libraryNewPlaylist => 'Neue Playlist';

  @override
  String get commonName => 'Name';

  @override
  String get libraryLikedSongs => 'Lieblingssongs';

  @override
  String get commonPlaylist => 'Playlist';

  @override
  String libraryPlaylistBy(String name) {
    return 'Playlist • $name';
  }

  @override
  String get navSettings => 'Einstellungen';

  @override
  String get searchHint => 'Was möchtest du hören?';

  @override
  String searchNoLibraryResults(String query) {
    return 'Keine Treffer für „$query“ in deiner Bibliothek.';
  }

  @override
  String get commonSongsTitle => 'Songs';

  @override
  String get commonArtist => 'Künstler';

  @override
  String get commonAlbums => 'Alben';

  @override
  String get libraryAllArtists => 'Alle Künstler';

  @override
  String get libraryTitle => 'Deine Bibliothek';

  @override
  String get libraryPlaylists => 'Playlists';

  @override
  String get librarySavedAlbums => 'Gespeicherte Alben';

  @override
  String get libraryAllAlbums => 'Alle Alben';

  @override
  String get libraryLoadingSongs => '… Songs';

  @override
  String get libraryNoAlbums => 'Keine Alben';

  @override
  String get librarySaveAlbumsHint => 'Speichere Alben mit ⊕, um sie hier zu sehen.';

  @override
  String commonDiscNumber(int number) {
    return 'CD $number';
  }

  @override
  String get libraryRemoveAlbum => 'Aus Bibliothek entfernen';

  @override
  String get librarySaveAlbum => 'In Bibliothek speichern';

  @override
  String get playerAddToPlaylist => 'Zur Playlist hinzufügen';

  @override
  String get editorCorrectAlbum => 'Album korrigieren';

  @override
  String get editorMatchAlbum => 'Album zuordnen';

  @override
  String get editorChangeCover => 'Cover ändern';

  @override
  String artistLibraryAlbums(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count Alben in deiner Bibliothek');
    return '$_temp0';
  }

  @override
  String get artistPopular => 'Beliebt';

  @override
  String get artistDiscography => 'Diskografie';

  @override
  String get libraryPublicPlaylist => 'Öffentliche Playlist';

  @override
  String get libraryRenamePlaylist => 'Playlist umbenennen';

  @override
  String get commonRename => 'Umbenennen';

  @override
  String get libraryMakePrivate => 'Privat machen';

  @override
  String get librarySharePlaylist => 'Für alle Nutzer freigeben';

  @override
  String get commonDelete => 'Löschen';

  @override
  String get libraryEmptyPlaylist => 'Noch keine Songs. Füge welche über das ⋯-Menü eines Songs hinzu.';

  @override
  String get libraryRemoveFromPlaylist => 'Aus dieser Playlist entfernen';

  @override
  String get homeGreetingNight => 'Gute Nacht';

  @override
  String get homeGreetingMorning => 'Guten Morgen';

  @override
  String get homeGreetingAfternoon => 'Guten Tag';

  @override
  String get homeGreetingEvening => 'Guten Abend';

  @override
  String get homeRecentlyPlayed => 'Zuletzt gehört';

  @override
  String get homeYourPlaylists => 'Deine Playlists';

  @override
  String get homeRecentlyAdded => 'Neu in der Bibliothek';

  @override
  String get homeEmptyLibrary =>
      'Deine Bibliothek ist noch leer.\nEin Admin kann im Dashboard einen Bibliotheks-Scan starten.';

  @override
  String get playerNothingPlaying => 'Gerade läuft nichts';

  @override
  String get playerQueue => 'Warteschlange';

  @override
  String get audiobooksBook => 'Hörbuch';

  @override
  String get playerGoToAudiobook => 'Zum Hörbuch';

  @override
  String get audiobooksChapters => 'Kapitel';

  @override
  String get playerEmptyQueue => 'Die Warteschlange ist leer';

  @override
  String get playerNowPlaying => 'Läuft gerade';

  @override
  String get playerNextUp => 'Als Nächstes';

  @override
  String get playerRemoveFromQueue => 'Aus Warteschlange entfernen';

  @override
  String get settingsAccount => 'Konto';

  @override
  String get settingsAdministratorSuffix => ' • Administrator';

  @override
  String get settingsDisplayName => 'Anzeigename';

  @override
  String get settingsChangePassword => 'Passwort ändern';

  @override
  String get settingsAppearance => 'Darstellung';

  @override
  String get settingsAccentColor => 'Akzentfarbe';

  @override
  String get settingsCustomColor => 'Eigene Farbe';

  @override
  String get commonCancel => 'Abbrechen';

  @override
  String get commonApply => 'Übernehmen';

  @override
  String get settingsNormalizeVolume => 'Lautstärke angleichen';

  @override
  String get settingsNormalizeVolumeHint => 'Nutzt ReplayGain, damit alle Songs ähnlich laut sind';

  @override
  String get settingsSignedInDevices => 'Angemeldete Geräte';

  @override
  String get settingsUnknownDevice => 'Unbekanntes Gerät';

  @override
  String get settingsCurrentDeviceSuffix => ' (dieses Gerät)';

  @override
  String settingsLastActive(String date) {
    return 'Zuletzt aktiv: $date';
  }

  @override
  String get commonSignOut => 'Abmelden';

  @override
  String get settingsCurrentPassword => 'Aktuelles Passwort';

  @override
  String get settingsNewPassword => 'Neues Passwort';

  @override
  String get commonChange => 'Ändern';

  @override
  String get settingsPasswordChanged => 'Passwort geändert';

  @override
  String get catalogDiscoverMore => 'Mehr entdecken';

  @override
  String get catalogDownloadHint => 'Was noch nicht in der Bibliothek ist, kannst du hier herunterladen.';

  @override
  String get catalogNoResults => 'Auch im Katalog nichts gefunden.';

  @override
  String get catalogAllInLibrary => 'Komplett in der Bibliothek';

  @override
  String catalogLibraryCount(int count, int total) {
    return '$count von $total in der Bibliothek';
  }

  @override
  String get catalogDownloadAlbum => 'Album herunterladen';

  @override
  String get catalogDownloadMissingSong => 'Fehlenden Song herunterladen';

  @override
  String catalogDownloadMissingSongs(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: 'Fehlende $count Songs herunterladen');
    return '$_temp0';
  }

  @override
  String get catalogOpenInLibrary => 'In Bibliothek öffnen';

  @override
  String get catalogEps => 'EPs';

  @override
  String get catalogSingles => 'Singles';

  @override
  String catalogArtistReleases(int count, int inLibrary) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Veröffentlichungen • $inLibrary in der Bibliothek',
    );
    return '$_temp0';
  }

  @override
  String get downloadsMine => 'Meine';

  @override
  String get downloadsAllUsers => 'Alle Nutzer';

  @override
  String get downloadsOpen => 'Offen';

  @override
  String get downloadsCompleted => 'Abgeschlossen';

  @override
  String get downloadsEmptyActive => 'Keine laufenden Downloads.\nSuche nach Musik und tippe auf ⤓.';

  @override
  String get downloadsEmptyCompleted => 'Noch nichts heruntergeladen.';

  @override
  String get commonSong => 'Song';

  @override
  String downloadsRequestedBySuffix(String name) {
    return 'von $name';
  }

  @override
  String get downloadsReject => 'Ablehnen';

  @override
  String get downloadsApprove => 'Freigeben';

  @override
  String get downloadsRejectRequest => 'Anfrage ablehnen';

  @override
  String get downloadsReasonOptional => 'Begründung (optional)';

  @override
  String get downloadsDownload => 'Download';

  @override
  String downloadsProgress(String status, int done, int total, String failed) {
    return '$status • $done/$total fertig$failed';
  }

  @override
  String downloadsFailedSuffix(int count) {
    return ' • $count fehlgeschlagen';
  }

  @override
  String downloadsRequestedBy(String name) {
    return 'Angefragt von $name';
  }

  @override
  String downloadsReason(String reason) {
    return 'Begründung: $reason';
  }

  @override
  String get downloadsRetryFailed => 'Fehlgeschlagene erneut versuchen';

  @override
  String get downloadsDeleteEntry => 'Eintrag löschen';

  @override
  String get catalogYouTubeMusic => 'YouTube Music';

  @override
  String get downloadsTorrent => 'Torrent';

  @override
  String get downloadsSearchingTorrent => 'Suche Torrent …';

  @override
  String downloadsTorrentProgress(String name, int progress) {
    return 'Torrent: $name ($progress %)';
  }

  @override
  String get downloadsImportingTorrent => 'Torrent wird importiert …';

  @override
  String downloadsTorrentName(String name) {
    return 'Torrent: $name';
  }

  @override
  String downloadsTorrentFallback(String error) {
    return 'Kein Torrent – lade über YouTube Music$error';
  }

  @override
  String commonDurationHoursMinutes(int hours, int minutes) {
    return '$hours Std. $minutes Min.';
  }

  @override
  String commonDurationMinutes(int minutes) {
    return '$minutes Min.';
  }

  @override
  String get audiobooksFinished => 'Beendet';

  @override
  String audiobooksTimeRemaining(String duration) {
    return 'Noch $duration';
  }

  @override
  String get audiobooksNotConfigured => 'Hörbücher sind auf diesem Server nicht eingerichtet.';

  @override
  String get audiobooksLoginTitle => 'Mit Audiobookshelf verbinden';

  @override
  String audiobooksLoginHint(String address) {
    return 'Melde dich mit deinem Audiobookshelf-Konto an$address. Dein Hörfortschritt bleibt mit allen Audiobookshelf-Apps synchron.';
  }

  @override
  String get authUsername => 'Benutzername';

  @override
  String get authPassword => 'Passwort';

  @override
  String get authSignIn => 'Anmelden';

  @override
  String get audiobooksNoLibrary => 'Keine Hörbuch-Bibliothek gefunden';

  @override
  String audiobooksSignOutUser(String name) {
    return 'Abmelden ($name)';
  }

  @override
  String get audiobooksSearchHint => 'Titel, Autor oder Serie suchen';

  @override
  String get audiobooksContinueListening => 'Weiterhören';

  @override
  String get audiobooksAllBooks => 'Alle Hörbücher';

  @override
  String get commonNothingFound => 'Nichts gefunden';

  @override
  String audiobooksNarrator(String name) {
    return 'gelesen von $name';
  }

  @override
  String get audiobooksStartOver => 'Von vorn beginnen';

  @override
  String get audiobooksMarkUnfinished => 'Als nicht beendet markieren';

  @override
  String get audiobooksMarkFinished => 'Als beendet markieren';

  @override
  String authCheckAddress(String error) {
    return '$error\nIst die Adresse richtig?';
  }

  @override
  String get authConnectTitle => 'Mit Server verbinden';

  @override
  String get authServerAddress => 'Server-Adresse';

  @override
  String get authConnect => 'Verbinden';

  @override
  String get commonRetry => 'Erneut versuchen';

  @override
  String get authOtherServer => 'Anderer Server';

  @override
  String authSignInTo(String name) {
    return 'Bei $name anmelden';
  }

  @override
  String get authCreateAccount => 'Konto erstellen';

  @override
  String authServer(String address) {
    return 'Server: $address';
  }

  @override
  String get authPasswordsMismatch => 'Passwörter stimmen nicht überein';

  @override
  String get authInvalidInvite => 'Einladung ungültig';

  @override
  String get authInvalidInviteHint =>
      'Dieser Einladungslink wurde bereits benutzt oder ist abgelaufen. Bitte frag einen Admin nach einem neuen Link.';

  @override
  String get authBackToLogin => 'Zur Anmeldung';

  @override
  String get authWelcomeAdmin => 'Willkommen! Admin-Konto anlegen';

  @override
  String get authFirstAccountHint => 'Das erste Konto auf diesem Server wird automatisch Administrator.';

  @override
  String get authPasswordMinimum => 'Passwort (min. 8 Zeichen)';

  @override
  String get authRepeatPassword => 'Passwort wiederholen';

  @override
  String get authRegister => 'Registrieren';

  @override
  String get authAlreadyHaveAccount => 'Ich habe schon ein Konto';

  @override
  String catalogAwaitingApproval(String title) {
    return '„$title“ wartet auf Freigabe durch einen Admin';
  }

  @override
  String catalogAlreadyInLibrary(String title) {
    return '„$title“ ist schon in deiner Bibliothek';
  }

  @override
  String catalogDownloadingTitle(String title) {
    return '„$title“ wird heruntergeladen';
  }

  @override
  String get catalogInYourLibrary => 'In deiner Bibliothek';

  @override
  String get catalogRequested => 'Angefragt';

  @override
  String get catalogDownload => 'Herunterladen';

  @override
  String get catalogInLibrary => 'In Bibliothek';

  @override
  String get downloadsStatusPendingApproval => 'Wartet auf Freigabe';

  @override
  String get downloadsStatusRunning => 'Läuft';

  @override
  String get commonDone => 'Fertig';

  @override
  String get downloadsStatusPartial => 'Teilweise fertig';

  @override
  String get downloadsStatusFailed => 'Fehlgeschlagen';

  @override
  String get downloadsStatusRejected => 'Abgelehnt';

  @override
  String get downloadsStatusCancelled => 'Abgebrochen';

  @override
  String get downloadsStatusQueued => 'In Warteschlange';

  @override
  String get downloadsStatusSearching => 'Suche Quelle …';

  @override
  String get downloadsStatusDownloading => 'Lädt herunter';

  @override
  String get downloadsStatusProcessing => 'Wird getaggt …';

  @override
  String get downloadsStatusExisting => 'Schon vorhanden';

  @override
  String get playerShuffle => 'Zufallswiedergabe';

  @override
  String get playerRemoveLiked => 'Aus Lieblingssongs entfernen';

  @override
  String get playerAddLiked => 'Zu Lieblingssongs hinzufügen';

  @override
  String get playerPlayNext => 'Als Nächstes spielen';

  @override
  String get playerAddToQueue => 'Zur Warteschlange hinzufügen';

  @override
  String get playerGoToAlbum => 'Zum Album';

  @override
  String get playerGoToArtist => 'Zum Künstler';

  @override
  String get editorCorrectMetadata => 'Metadaten korrigieren';

  @override
  String libraryAddedToPlaylist(String name) {
    return 'Zu „$name“ hinzugefügt';
  }

  @override
  String get commonSave => 'Speichern';

  @override
  String get playerSkipBack => '30 Sekunden zurück';

  @override
  String get playerSkipForward => '30 Sekunden vor';

  @override
  String get playerPrevious => 'Zurück';

  @override
  String get playerNext => 'Weiter';

  @override
  String get playerRepeat => 'Wiederholen';

  @override
  String get playerSpeed => 'Geschwindigkeit';

  @override
  String get playerSleepTimer => 'Sleep-Timer';

  @override
  String playerSleepTimerTime(String time) {
    return 'Sleep-Timer: pausiert um $time';
  }

  @override
  String playerTimerMinutes(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(minutes, locale: localeName, other: '$minutes Minuten');
    return '$_temp0';
  }

  @override
  String get playerDisableTimer => 'Timer ausschalten';

  @override
  String get playerFullscreen => 'Vollbild';

  @override
  String commonDurationMinutesSeconds(int minutes, int seconds) {
    return '$minutes Min. $seconds Sek.';
  }

  @override
  String get updateAllowInstall => 'Bitte erlaube Resonance in den Android-Einstellungen, Apps zu installieren.';

  @override
  String updateFailedCode(String code) {
    return 'Update fehlgeschlagen ($code). Bitte erneut versuchen.';
  }

  @override
  String updateFailedMessage(String error) {
    return 'Update fehlgeschlagen: $error';
  }

  @override
  String get updateInProgress => 'App wird aktualisiert';

  @override
  String get updateDownloadStarting => 'Download startet …';

  @override
  String updateDownloadProgress(int percent) {
    return 'Download $percent %';
  }

  @override
  String get commonClose => 'Schließen';

  @override
  String updateAvailableTitle(String version) {
    return 'Neue App-Version $version verfügbar';
  }

  @override
  String get updateInstall => 'Installieren';

  @override
  String updateInstalledVersion(String version) {
    return 'App-Version $version';
  }

  @override
  String updateAvailableVersion(String version) {
    return 'Version $version ist verfügbar';
  }

  @override
  String get updateCurrent => 'Aktuell';

  @override
  String get updateAction => 'Aktualisieren';

  @override
  String get updateCheck => 'Nach Updates suchen';

  @override
  String get updateAlreadyCurrent => 'Die App ist aktuell';

  @override
  String get adminImportCleanupTitle => 'Bibliothek aufräumen?';

  @override
  String get adminImportCleanupHint =>
      'Alle Songs der Bibliothek werden per Audio-Fingerabdruck erkannt, neu getaggt, mit Cover versehen und nach „Künstler/Album (Jahr)/Nr - Titel“ umbenannt. Die Dateien werden dabei direkt verändert.\n\nLikes, Playlists und Verlauf bleiben erhalten. Bei großen Bibliotheken dauert das mehrere Stunden.';

  @override
  String get adminImportCleanupConfirm => 'Aufräumen';

  @override
  String get adminImportFolder => 'Import-Ordner';

  @override
  String adminImportPendingFiles(int count, String mode) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Audiodateien warten • Modus: $mode',
    );
    return '$_temp0';
  }

  @override
  String get adminImportCopyHint => 'Kopieren (Originale bleiben unverändert)';

  @override
  String get adminImportMove => 'Verschieben';

  @override
  String get adminImportAcoustIdHint =>
      'Kein AcoustID-Schlüssel eingetragen – Songs werden nur über ihre vorhandenen Tags erkannt. Einen kostenlosen Schlüssel gibt es auf acoustid.org/new-application; eintragen unter „Server“.';

  @override
  String get adminImportStart => 'Import starten';

  @override
  String get adminImportCleanup => 'Bibliothek aufräumen';

  @override
  String get adminImportHistory => 'Verlauf';

  @override
  String get adminImportEmptyHistory => 'Noch kein Import gelaufen.';

  @override
  String get adminImportWaiting => 'Wartet';

  @override
  String adminImportBatchTitle(String mode) {
    return 'Import ($mode)';
  }

  @override
  String adminImportFileProgress(int count, int total) {
    String _temp0 = intl.Intl.pluralLogic(total, locale: localeName, other: '$count von $total Dateien');
    return '$_temp0';
  }

  @override
  String get adminImportIdentified => 'Erkannt';

  @override
  String get adminImportImported => 'Importiert';

  @override
  String get adminImportDuplicates => 'Duplikate';

  @override
  String get adminImportUnidentified => 'Nicht erkannt';

  @override
  String get adminImportErrors => 'Fehler';

  @override
  String get adminImportMethodAlbumFingerprint => 'Erkannt per Fingerabdruck (komplettes Album)';

  @override
  String get adminImportMethodTrackFingerprint => 'Erkannt per Fingerabdruck (einzelner Song)';

  @override
  String get adminImportMethodTags => 'Erkannt über vorhandene Tags (Katalog)';

  @override
  String get adminImportMethodUnidentified => 'Nicht erkannt – vorhandene Tags übernommen';

  @override
  String get adminTabOverview => 'Übersicht';

  @override
  String get adminTabUsers => 'Benutzer';

  @override
  String get adminTabInvites => 'Einladungen';

  @override
  String get adminTabImport => 'Import';

  @override
  String get adminTabReview => 'Zu prüfen';

  @override
  String get adminTabServer => 'Server';

  @override
  String get adminStorage => 'Speicher';

  @override
  String get adminPlaytime => 'Spielzeit';

  @override
  String commonDurationHours(String hours) {
    return '$hours Std.';
  }

  @override
  String get adminScanHint =>
      'Der schnelle Scan liest nur neue und geänderte Dateien ein. Der vollständige Scan liest alle Tags und Cover neu.';

  @override
  String get adminQuickScan => 'Schneller Scan';

  @override
  String get adminFullScan => 'Vollständiger Scan';

  @override
  String get adminJobs => 'Aufgaben';

  @override
  String get adminNoJobs => 'Noch keine Aufgaben';

  @override
  String get adminLibraryScan => 'Bibliotheks-Scan';

  @override
  String get adminUserYouSuffix => ' (du)';

  @override
  String get adminUserDisabledSuffix => ' • deaktiviert';

  @override
  String adminUserLastSeenSuffix(String date) {
    return ' • zuletzt $date';
  }

  @override
  String adminNewPasswordFor(String name) {
    return 'Neues Passwort für $name';
  }

  @override
  String get adminPasswordSet => 'Passwort gesetzt, alle Geräte abgemeldet';

  @override
  String adminDeleteUserTitle(String name) {
    return '$name löschen?';
  }

  @override
  String get adminDeleteUserHint => 'Playlists und Verlauf werden ebenfalls gelöscht.';

  @override
  String get adminRemoveAdmin => 'Admin-Rechte entziehen';

  @override
  String get adminMakeAdmin => 'Zum Admin machen';

  @override
  String get adminEnableUser => 'Aktivieren';

  @override
  String get adminDisableUser => 'Deaktivieren';

  @override
  String get adminResetPassword => 'Passwort zurücksetzen';

  @override
  String get adminPasswordMinimum => 'Min. 8 Zeichen';

  @override
  String get adminCreateInviteTitle => 'Einladungslink erstellen';

  @override
  String get adminInviteNote => 'Notiz (z. B. für wen)';

  @override
  String get adminInviteValidity => 'Gültig für';

  @override
  String get adminInviteOneDay => '1 Tag';

  @override
  String get adminInviteThreeDays => '3 Tage';

  @override
  String get adminInviteSevenDays => '7 Tage';

  @override
  String get adminInviteThirtyDays => '30 Tage';

  @override
  String get adminInviteUnlimited => 'Unbegrenzt';

  @override
  String get adminInviteAsAdmin => 'Als Admin registrieren';

  @override
  String get commonCreate => 'Erstellen';

  @override
  String get adminInviteLink => 'Einladungslink';

  @override
  String get adminInviteLinkHint => 'Der Link kann genau einmal benutzt werden. Er wird nur jetzt angezeigt.';

  @override
  String get adminLinkCopied => 'Link kopiert';

  @override
  String get commonCopy => 'Kopieren';

  @override
  String get adminNewInvite => 'Neuer Link';

  @override
  String get adminNoInvites => 'Noch keine Einladungen.\nErstelle einen Link, um jemanden einzuladen.';

  @override
  String get adminInvitation => 'Einladung';

  @override
  String adminInviteUsed(String name, String date) {
    return 'Benutzt von $name am $date';
  }

  @override
  String get adminInviteExpired => 'Abgelaufen';

  @override
  String adminInviteOpen(String expiry, String role) {
    return 'Offen • $expiry$role';
  }

  @override
  String get adminInviteNoExpiry => 'läuft nicht ab';

  @override
  String adminInviteExpires(String date) {
    return 'gültig bis $date';
  }

  @override
  String get adminInviteAdminSuffix => ' • Admin';

  @override
  String get adminServerName => 'Servername';

  @override
  String get adminRegistration => 'Registrierung';

  @override
  String get adminRegistrationInviteOnly => 'Nur mit Einladungslink';

  @override
  String get adminRegistrationInviteHint => 'Admins erstellen einmalig nutzbare Links (empfohlen)';

  @override
  String get adminRegistrationPublic => 'Öffentliche Registrierung';

  @override
  String get adminRegistrationPublicHint => 'Jeder, der den Server erreicht, kann ein Konto anlegen';

  @override
  String get adminLibraryImport => 'Bibliothek & Import';

  @override
  String get adminAcoustIdKey => 'AcoustID-Schlüssel';

  @override
  String get adminAcoustIdNotSet => 'Nicht gesetzt – kostenlos auf acoustid.org/new-application';

  @override
  String get adminConfigured => 'Gesetzt';

  @override
  String get adminAcoustIdHint => 'Für die Erkennung per Audio-Fingerabdruck';

  @override
  String get adminMoveImportedFiles => 'Importierte Dateien verschieben';

  @override
  String get adminMoveImportedFilesHint => 'Der Import-Ordner wird danach geleert';

  @override
  String get adminCopyImportedFiles => 'Importierte Dateien kopieren';

  @override
  String get adminCopyImportedFilesHint => 'Originale bleiben unverändert im Import-Ordner';

  @override
  String get adminImportUnidentifiedFiles => 'Nicht erkannte Dateien trotzdem importieren';

  @override
  String get adminImportUnidentifiedFilesHint =>
      'Mit ihren vorhandenen Tags; sonst bleiben sie im Import-Ordner liegen';

  @override
  String get adminAutoImport => 'Import-Ordner automatisch importieren';

  @override
  String get adminAutoImportHint => 'Prüft alle 5 Minuten auf neue Dateien (nur im Modus „Verschieben“)';

  @override
  String get adminSongRadio => 'Song-Radio';

  @override
  String get adminRadioAutoDownload => 'Fehlende Songs automatisch herunterladen';

  @override
  String get adminRadioAutoDownloadHint =>
      'Ähnliche Songs, die noch nicht in der Bibliothek sind, landen in der Download-Warteschlange';

  @override
  String get adminRadioTemporary => 'Radio-Downloads sind temporär';

  @override
  String adminRadioTemporaryHint(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'Werden nach $days Tagen gelöscht, außer jemand liked sie oder fügt sie einer Playlist hinzu',
    );
    return '$_temp0';
  }

  @override
  String get adminRadioRetention => 'Aufbewahrung temporärer Songs (Tage)';

  @override
  String get adminEnableAudiobookshelf => 'Audiobookshelf einbinden';

  @override
  String get adminEnableAudiobookshelfHint =>
      'Zeigt den Tab „Hörbücher“. Jeder Benutzer meldet sich dort mit seinem eigenen Audiobookshelf-Konto an.';

  @override
  String get adminAudiobookshelfAddress => 'Audiobookshelf-Adresse';

  @override
  String get adminAudiobookshelfAddressHint => 'z. B. https://audio.example.com – auch für externe Apps gedacht';

  @override
  String get adminAlbumTorrents => 'Torrents für Alben';

  @override
  String get adminAlbumTorrentsHint =>
      'Sucht Alben zuerst über Prowlarr (öffentliche Tracker) und lädt sie mit qBittorrent über das VPN. Was dort fehlt, kommt von YouTube Music.';

  @override
  String get adminProwlarrApiKey => 'Prowlarr-API-Schlüssel';

  @override
  String get adminProwlarrApiKeyHint => 'Prowlarr → Settings → General → API Key';

  @override
  String get adminQbittorrentUsername => 'qBittorrent-Benutzer';

  @override
  String get adminQbittorrentPassword => 'qBittorrent-Passwort';

  @override
  String get adminMinimumSeeders => 'Mindestanzahl Seeder';

  @override
  String get adminTorrentTimeout => 'Aufgeben nach … Minuten ohne Fortschritt';

  @override
  String get adminYouTubeSource => 'YouTube Music als Quelle';

  @override
  String get adminYouTubeSourceHint => 'Lädt Songs über yt-dlp von YouTube Music (Opus, ca. 130–160 kbit/s)';

  @override
  String get adminQualityUpgrades => 'Qualitäts-Upgrades';

  @override
  String get adminQualityUpgradesHint =>
      'Songs in niedriger Qualität (z. B. von YouTube) später durch FLAC/MP3 320 ersetzen';

  @override
  String get adminAutoApprove => 'Anfragen automatisch genehmigen';

  @override
  String get adminAutoApproveHint => 'Sonst muss ein Admin Anfragen von Benutzern freigeben';

  @override
  String get adminDailyLimit => 'Tageslimit pro Benutzer';

  @override
  String adminDailyLimitHint(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Max. $count automatische Downloads pro Tag',
    );
    return '$_temp0';
  }

  @override
  String get adminDownloadsPerDay => 'Downloads pro Benutzer und Tag';

  @override
  String get adminNotConfigured => 'Nicht gesetzt';

  @override
  String get adminTestConnection => 'Verbindung testen';

  @override
  String get adminProwlarr => 'Prowlarr';

  @override
  String get adminQbittorrent => 'qBittorrent';

  @override
  String editorSavedTrack(String title, String artist, String album) {
    return 'Gespeichert: $title – $artist ($album)';
  }

  @override
  String editorBitrate(int bitrate) {
    return '$bitrate kbit/s';
  }

  @override
  String get editorTabSearch => 'Suchen';

  @override
  String get editorTabFingerprint => 'Fingerabdruck';

  @override
  String get editorTabEdit => 'Bearbeiten';

  @override
  String get editorSearchTrackHint => 'Künstler und Titel';

  @override
  String get editorChooseTrackHint => 'Tippe auf den richtigen Song – Tags, Cover und Dateiname werden übernommen.';

  @override
  String get editorFingerprintSearching => 'Audio-Fingerabdruck wird abgeglichen …';

  @override
  String get editorFingerprintUnknown =>
      'AcoustID kennt diese Aufnahme nicht. Versuche es über „Suchen“ oder „Bearbeiten“.';

  @override
  String get editorUnknownTitle => 'Unbekannter Titel';

  @override
  String editorFingerprintScore(int percent) {
    return '   $percent % Übereinstimmung';
  }

  @override
  String get editorAutoSelectAlbum => 'Originalalbum automatisch wählen';

  @override
  String get editorUnknownAlbum => 'Unbekanntes Album';

  @override
  String editorTrackNumberWithTotal(int number, String total) {
    return 'Nr. $number$total';
  }

  @override
  String editorTrackTotalSuffix(int total) {
    return ' von $total';
  }

  @override
  String get editorNumbersOnly => 'Bitte nur Zahlen bei Jahr, Nr. und CD eingeben';

  @override
  String get editorNoChanges => 'Keine Änderungen';

  @override
  String get editorTitle => 'Titel';

  @override
  String get editorSwapTitleArtist => 'Titel und Künstler tauschen';

  @override
  String get editorAlbumArtist => 'Album-Künstler';

  @override
  String get editorYear => 'Jahr';

  @override
  String get editorTrackNumber => 'Nr.';

  @override
  String get editorGenre => 'Genre';

  @override
  String get editorManualHint =>
      'Leere Felder bleiben unverändert. Die Datei wird danach nach „Album-Künstler/Album (Jahr)/Nr - Titel“ umbenannt.';

  @override
  String editorMatchedSongs(int count, int total) {
    String _temp0 = intl.Intl.pluralLogic(total, locale: localeName, other: '$count von $total Songs zugeordnet');
    return '$_temp0';
  }

  @override
  String get editorUnmatchedSongs => 'Nicht zugeordnet (unverändert):';

  @override
  String get editorSearchAlbumHint => 'Künstler und Album oder MusicBrainz-Link';

  @override
  String editorMatchAlbumHint(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Die $count Songs dieses Albums werden per Titel, Position und Länge den Songs der gewählten Veröffentlichung zugeordnet. Was nicht passt, bleibt unverändert.',
    );
    return '$_temp0';
  }

  @override
  String get editorUseMusicBrainzRelease => 'MusicBrainz-Veröffentlichung verwenden';

  @override
  String get editorRetagging => 'Songs werden neu getaggt …';

  @override
  String get editorCoverSaved => 'Cover gespeichert';

  @override
  String get editorCoverSuggestionsHint =>
      'Vorschläge von MusicBrainz und Deezer. Das Cover wird in alle Songs des Albums eingebettet.';

  @override
  String get editorUploadImage => 'Bild hochladen';

  @override
  String get editorNoCoverSuggestions => 'Keine Vorschläge gefunden';

  @override
  String get editorNoCover => 'Ohne Cover';

  @override
  String editorAlbumCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count Alben');
    return '$_temp0';
  }

  @override
  String get editorLoadMore => 'Mehr laden';

  @override
  String get editorAllDone => 'Alles erledigt 🎉';

  @override
  String get commonOk => 'OK';

  @override
  String get editorDisc => 'CD';

  @override
  String get catalogEp => 'EP';

  @override
  String get adminImportCopyMode => 'kopieren';

  @override
  String get adminImportMoveMode => 'verschieben';

  @override
  String get adminLibrary => 'Bibliothek';

  @override
  String commonSongs(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count Songs', one: '1 Song');
    return '$_temp0';
  }

  @override
  String get commonArtists => 'Künstler';

  @override
  String get adminUserRole => 'Benutzer';

  @override
  String get authServerAddressExample => 'musik.example.com';

  @override
  String get spotifyTitle => 'Von Spotify importieren';

  @override
  String get spotifyLinkHeading => 'Playlist per Link importieren';

  @override
  String get spotifyLinksHint =>
      'Füge Links zu öffentlichen Spotify-Playlists ein, einen pro Zeile. Ohne verbundenes Spotify-Konto werden höchstens 100 Songs pro Playlist übernommen.';

  @override
  String get spotifyLinkPlaceholder => 'https://open.spotify.com/playlist/…';

  @override
  String get spotifyImport => 'Importieren';

  @override
  String get spotifyNotConfigured =>
      'Spotify ist auf diesem Server noch nicht eingerichtet. Ein Admin kann das im Admin-Dashboard unter „Server“ erledigen.';

  @override
  String get spotifyConnectHint =>
      'Verbinde dein Spotify-Konto, um deine Lieblingssongs und eigenen Playlists in Resonance zu übernehmen.';

  @override
  String get spotifyConnect => 'Mit Spotify verbinden';

  @override
  String get spotifyWaiting => 'Melde dich im geöffneten Fenster bei Spotify an und komm danach hierher zurück.';

  @override
  String spotifyConnectedAs(String name) {
    return 'Verbunden als $name';
  }

  @override
  String get spotifyDisconnect => 'Trennen';

  @override
  String get spotifyLikedSongs => 'Lieblingssongs';

  @override
  String spotifyLikedHint(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count Songs', one: '1 Song');
    return '$_temp0 · werden in Resonance geliked';
  }

  @override
  String get spotifyPlaylistsHeading => 'Deine Playlists';

  @override
  String get spotifyPlaylistsNote =>
      'Spotify gibt nur deine eigenen Playlists und solche frei, an denen du mitarbeitest.';

  @override
  String spotifyPlaylistSubtitle(int count, String owner) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count Songs', one: '1 Song');
    return '$_temp0 · $owner';
  }

  @override
  String get spotifyAlreadyImported => 'bereits importiert – wird abgeglichen';

  @override
  String get spotifyDownloadMissing => 'Fehlende Songs herunterladen';

  @override
  String get spotifyDownloadMissingHint =>
      'Songs, die noch nicht in der Bibliothek sind, werden angefragt und nach dem Download automatisch einsortiert.';

  @override
  String get spotifyStart => 'Import starten';

  @override
  String get spotifyNothingSelected => 'Wähle die Lieblingssongs oder mindestens eine Playlist aus.';

  @override
  String get spotifyStarted => 'Import gestartet';

  @override
  String get spotifyHistory => 'Bisherige Importe';

  @override
  String get spotifyStatusQueued => 'Wartet';

  @override
  String get spotifyStatusRunning => 'Läuft';

  @override
  String get spotifyStatusDone => 'Fertig';

  @override
  String get spotifyStatusFailed => 'Fehlgeschlagen';

  @override
  String spotifyImportCounts(int matched, int total, int missing, int requested) {
    return '$matched von $total gefunden · $missing fehlen · $requested angefragt';
  }

  @override
  String get spotifyShowMissing => 'Fehlende anzeigen';

  @override
  String get spotifyMissingTitle => 'Nicht in der Bibliothek';

  @override
  String get adminSpotifyGroup => 'Spotify-Import';

  @override
  String get adminSpotifyClientId => 'Spotify Client ID';

  @override
  String get adminSpotifyClientSecret => 'Spotify Client Secret';

  @override
  String adminSpotifyHint(String uri) {
    return 'developer.spotify.com/dashboard → App anlegen, Redirect URI: $uri';
  }

  @override
  String get audiobooksViewLibrary => 'Bibliothek';

  @override
  String get audiobooksViewSeries => 'Serien';

  @override
  String get audiobooksViewAuthors => 'Autoren';

  @override
  String get audiobooksViewNarrators => 'Sprecher';

  @override
  String audiobooksBookCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count Hörbücher', one: '1 Hörbuch');
    return '$_temp0';
  }

  @override
  String get albumFindMissing => 'Fehlende Songs suchen';

  @override
  String get adminDeleteSong => 'Song löschen';

  @override
  String get adminDeleteAlbum => 'Album löschen';

  @override
  String adminDeleteSongConfirm(String title) {
    return '„$title“ wird endgültig vom Server gelöscht, auch die Datei.';
  }

  @override
  String adminDeleteAlbumConfirm(String title) {
    return 'Das Album „$title“ wird mit allen Songs endgültig vom Server gelöscht, auch die Dateien.';
  }

  @override
  String get adminDeleted => 'Gelöscht';

  @override
  String get libraryShareWithUsers => 'Mit bestimmten Nutzern teilen';

  @override
  String get libraryNoOtherUsers => 'Es gibt noch keine anderen Nutzer.';

  @override
  String librarySharedWith(String names) {
    return 'Geteilt mit $names';
  }

  @override
  String albumMissingTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Songs nicht in deiner Bibliothek',
      one: '1 Song nicht in deiner Bibliothek',
    );
    return '$_temp0';
  }

  @override
  String get radioStartSong => 'Song-Radio starten';

  @override
  String get radioStartAlbum => 'Album-Radio starten';

  @override
  String get radioKind => 'Radio';

  @override
  String get radioKeep => 'Als Playlist behalten';

  @override
  String radioDownloading(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count fehlende Songs werden geladen und dann zum Radio hinzugefügt',
      one: '1 fehlender Song wird geladen und dann zum Radio hinzugefügt',
    );
    return '$_temp0';
  }

  @override
  String get libraryRadios => 'Radios';

  @override
  String get adminRadioMaxDownloads => 'Max. Downloads pro Radio-Start';

  @override
  String get adminRadioPlaylistRetention => 'Radios aufbewahren (Tage seit letzter Nutzung, 0 = immer)';

  @override
  String get offlineBanner => 'Offline – nur heruntergeladene Musik';

  @override
  String get offlineEmptyHint => 'Lade Alben und Playlists herunter, um sie offline zu hören.';

  @override
  String get offlineDownloaded => 'Heruntergeladen';

  @override
  String get offlineDownload => 'Herunterladen';

  @override
  String get offlineRemoveTitle => 'Download entfernen?';

  @override
  String get offlineQuality => 'Downloadqualität';

  @override
  String get offlineQualityNormal => 'Normal (Opus 160 kbit/s)';

  @override
  String get offlineQualityHigh => 'Hoch (Opus 256 kbit/s)';

  @override
  String get offlineQualityOriginal => 'Original (verlustfrei, braucht viel Speicher)';

  @override
  String get offlineWifiOnly => 'Nur über WLAN herunterladen';

  @override
  String get offlineStorage => 'Speicherbelegung';

  @override
  String offlineStorageUsed(String size, int count) {
    return '$size • $count Songs';
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
    return '$count Songs werden heruntergeladen';
  }

  @override
  String offlineProgress(int done, int total) {
    return '$done von $total heruntergeladen';
  }

  @override
  String get offlineClearAll => 'Alle Downloads löschen';

  @override
  String get offlineClearConfirm => 'Alle Downloads löschen?';

  @override
  String get mixKind => 'Mix';

  @override
  String get mixSave => 'Als Playlist speichern';

  @override
  String get homeMadeForYou => 'Für dich erstellt';

  @override
  String get homeGenreMixes => 'Deine Genres';

  @override
  String get lyricsTitle => 'Songtext';

  @override
  String get lyricsExpand => 'Vollbild';

  @override
  String get lyricsUnsynced => 'Diese Songtexte sind nicht synchronisiert.';

  @override
  String get lyricsInstrumental => 'Instrumental';

  @override
  String get lyricsNotFound => 'Für diesen Song gibt es keinen Songtext.';

  @override
  String get lyricsAttribution => 'Songtext von LRCLIB';

  @override
  String get adminLyricsOnline => 'Songtexte online suchen (LRCLIB)';

  @override
  String get adminLyricsOnlineHint =>
      'Für Songs ohne eigene Songtexte werden synchronisierte Texte von lrclib.net geladen.';

  @override
  String get redownloadMenu => 'Falsche Version? Neu herunterladen';

  @override
  String get redownloadTitle => 'Neu herunterladen';

  @override
  String get redownloadExplanation =>
      'Der Song wird erneut gesucht und ersetzt. Die bisher verwendete Quelle wird übersprungen. Likes und Playlists bleiben erhalten.';

  @override
  String get redownloadYoutubeLabel => 'YouTube-Link (optional)';

  @override
  String get redownloadYoutubeHint => 'Falls du eine bestimmte Version willst';

  @override
  String get redownloadStarted => 'Neu-Download gestartet';

  @override
  String get redownloadAwaitingApproval => 'Anfrage gesendet – ein Admin muss sie freigeben';

  @override
  String get downloadsRedownload => 'Neu-Download';

  @override
  String get audioBrowseHome => 'Startseite';

  @override
  String get settingsCrossfade => 'Crossfade';

  @override
  String get settingsCrossfadeOff => 'Aus';

  @override
  String settingsCrossfadeSeconds(int seconds) {
    return '$seconds s';
  }

  @override
  String get settingsSubsonicTitle => 'Andere Musik-Apps (Subsonic)';

  @override
  String get settingsSubsonicSubtitle => 'Nutze Resonance in Apps wie Symfonium oder Feishin';

  @override
  String settingsSubsonicConnection(String serverUrl, String username) {
    return 'Server: $serverUrl\nBenutzername: $username';
  }

  @override
  String get settingsSubsonicConfigured => 'Ein App-Passwort ist eingerichtet.';

  @override
  String get settingsSubsonicRegenerate => 'Neues Passwort erzeugen';

  @override
  String get settingsSubsonicRemove => 'Entfernen';

  @override
  String get settingsSubsonicHint =>
      'Erzeuge ein App-Passwort und gib es in der anderen App als Passwort ein. Dein normales Passwort funktioniert dort nicht.';

  @override
  String get settingsSubsonicGenerate => 'Passwort erzeugen';

  @override
  String get settingsSubsonicCopied => 'Kopiert';

  @override
  String get settingsSubsonicShownOnce => 'Wird nur jetzt angezeigt.';

  @override
  String get adminIntegrations => 'Integrationen';

  @override
  String get adminDiscordClientId => 'Discord-Anwendungs-ID';

  @override
  String get adminDiscordClientIdHint =>
      'Für den Discord-Status der Desktop-App. Anwendung unter discord.com/developers anlegen und die Application ID hier eintragen.';

  @override
  String get settingsDiscordPresence => 'Discord-Status anzeigen';

  @override
  String get settingsDiscordPresenceHint => 'Zeigt in Discord an, was du gerade hörst';

  @override
  String get settingsDiscordNotConfigured => 'Vom Admin noch nicht eingerichtet';

  @override
  String discordPresenceArtist(String artist) {
    return 'von $artist';
  }
}
