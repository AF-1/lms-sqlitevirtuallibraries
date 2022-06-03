#
# SQLite Virtual Libraries
#
# (c) 2022 AF
#
# GPLv3 license
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#

package Plugins::SQLiteVirtualLibraries::Plugin;

use strict;
use warnings;
use utf8;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Text;
use Slim::Schema;
use File::Basename;
use File::Slurp; # for read_file
use HTML::Entities; # for parsing
use File::Spec::Functions qw(:ALL);
use Time::HiRes qw(time);
use Data::Dumper;

use Plugins::SQLiteVirtualLibraries::Settings;

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.sqlitevirtuallibraries',
	'defaultLevel' => 'WARN',
	'description' => 'PLUGIN_SQLITEVIRTUALLIBRARIES',
});
my $serverPrefs = preferences('server');
my $prefs = preferences('plugin.sqlitevirtuallibraries');
my $isPostScanCall = 0;
my $VLibDefinitions;

sub initPlugin {
	my $class = shift;
	$class->SUPER::initPlugin(@_);

	initPrefs();

	if (main::WEBUI) {
		Plugins::SQLiteVirtualLibraries::Settings->new($class);
	}

	Slim::Control::Request::subscribe(sub{
		initVirtualLibrariesDelayed();
		$isPostScanCall = 1;
	},[['rescan'],['done']]);

}

sub initPrefs {
	$prefs->init({
		sqlcustomvldefdir_parentfolderpath => $serverPrefs->get('playlistdir'),
		browsemenus_parentfoldername => 'My SQLVL Menus',
		browsemenus_parentfoldericon => 1,
		compisrandom_genreexcludelist => 'Classical;;Classical - Opera;;Classical - BR;;Soundtrack - TV & Movie Themes',
		pluginvlibdeffolder => sub {
			my @pluginDirs = Slim::Utils::OSDetect::dirsFor('Plugins');
			for my $plugindir (@pluginDirs) {
				if (-d catdir($plugindir, 'SQLiteVirtualLibraries', 'VirtualLibraries')) {
					my $pluginVLibDefFolder = catdir($plugindir, 'SQLiteVirtualLibraries', 'VirtualLibraries');
					$log->debug('pluginVLibDefFolder = '.Dumper($pluginVLibDefFolder));
					return $pluginVLibDefFolder;
				}
			}
			return undef;
		}
	});
	createCustomVLdefDir();

	$prefs->setValidate(sub {
		return if (!$_[1] || !(-d $_[1]) || (main::ISWINDOWS && !(-d Win32::GetANSIPathName($_[1]))) || !(-d Slim::Utils::Unicode::encode_locale($_[1])));
		my $sqlcustomvldefdir = catfile($_[1], 'SQLVL-VirtualLibrary-definitions');
		eval {
			mkdir($sqlcustomvldefdir, 0755) unless (-d $sqlcustomvldefdir);
			chdir($sqlcustomvldefdir);
		} or do {
			$log->warn("Could not create or access custom vlib def directory in parent folder '$_[1]'!");
			return;
		};
		$prefs->set('sqlcustomvldefdir', $sqlcustomvldefdir);
		return 1;
	}, 'sqlcustomvldefdir_parentfolderpath');

	$prefs->setValidate({
		validator => sub {
			if (defined $_[1] && $_[1] ne '') {
				return if $_[1] =~ m|[\^{}$@<>"#%?*:/\|\\]|;
				return if $_[1] =~ m|.{61,}|;
			}
			return 1;
		}
	}, 'browsemenus_parentfoldername');

	$prefs->setValidate({
		validator => sub {
			return if $_[1] =~ m|[\^{}$@<>"#%?*:/\|\\]|;
			return 1;
		}
	}, 'compisrandom_genreexcludelist');

	$prefs->setChange(sub {
			$log->debug('VL config changed. Reinitializing VLs + menus.');
			initVirtualLibrariesDelayed();
		}, 'virtuallibrariesmatrix', 'vlstempdisabled');
	$prefs->setChange(sub {
			$log->debug('SQLVL parent folder name or icon changed. Reinitializing collected VL menus.');
			initCollectedVLMenus();
		}, 'browsemenus_parentfoldername', 'browsemenus_parentfoldericon');
	$prefs->setChange(sub {
			$log->debug('compisrandom_genreexcludelist changed.');
			Slim::Music::VirtualLibraries->unregisterLibrary('PLUGIN_SQLVL_VLID_COMPISRANDOM');
			Slim::Menu::BrowseLibrary->deregisterNode('PLUGIN_SQLVL_MENUID_COMPIS_RANDOM');
			initVirtualLibrariesDelayed();
		}, 'compisrandom_genreexcludelist');
}

sub postinitPlugin {
	unless (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		initVirtualLibrariesDelayed();
	}
}

sub initVirtualLibraries {
	$log->debug('Start initializing VLs.');

	# deregister all SQLVL menus
	$log->debug('Deregistering SQLVL menus.');
	deregAllMenus();

	my $LMS_virtuallibraries = Slim::Music::VirtualLibraries->getLibraries();
	$log->debug('Found these registered LMS virtual libraries: '.Dumper($LMS_virtuallibraries));

	## check if VLs + VL menus are globally disabled
	if (defined ($prefs->get('vlstempdisabled'))) {
		# unregister VLs
		$log->debug('VLs globally disabled. Unregistering SQLVL VLs.');
		foreach my $thisVLrealID (keys %{$LMS_virtuallibraries}) {
			my $thisVLID = $LMS_virtuallibraries->{$thisVLrealID}->{'id'};
			$log->debug('VLID: '.$thisVLID.' - RealID: '.$thisVLrealID);
			if (starts_with($thisVLID, 'PLUGIN_SQLVL_VLID_') == 0) {
				Slim::Music::VirtualLibraries->unregisterLibrary($thisVLrealID);
			}
		}
		return;
	}

	my $started = time();
	my $virtuallibrariesmatrix = $prefs->get('virtuallibrariesmatrix');
	$log->debug('virtuallibrariesmatrix = '.Dumper($virtuallibrariesmatrix));

	## update list of available virtual library SQLite definitions
	getVirtualLibraryDefinitions();

	# delete configs in virtuallibrariesmatrix referring to (external = not SQLVL) virtual libraries that no longer exist
	foreach my $virtuallibrariesconfig (keys %{$virtuallibrariesmatrix}) {
		my $sqlitedefid = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'sqlitedefid'};
		next if $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'vlibsource'} != 3;
		my $configIsValid = 0;
		foreach my $thisVLrealID (keys %{$LMS_virtuallibraries}) {
			my $thisVLID = $LMS_virtuallibraries->{$thisVLrealID}->{'id'};
			$log->debug('VLID: '.$thisVLID.' - RealID: '.$thisVLrealID.' -- sqlitedefid = '.$sqlitedefid);
			if ($sqlitedefid eq $thisVLID) {
				$log->debug("Config '$sqlitedefid' is valid. Source VL exists.");
				$configIsValid = 1;
				last;
			}
		}
		next if $configIsValid;
		$log->debug("Deleting virtual matrix config with ID '$sqlitedefid' because it's based on external (= not SQLVL) virtual library that no longer exists.");
		delete $virtuallibrariesmatrix->{$virtuallibrariesconfig};
		$prefs->set('virtuallibrariesmatrix', $virtuallibrariesmatrix);
	}

	### create/register VLs

	if (keys %{$virtuallibrariesmatrix} > 0) {
		# delete configs in virtuallibrariesmatrix referring to SQLite definition files that no longer exist
		foreach my $virtuallibrariesconfig (keys %{$virtuallibrariesmatrix}) {
			my $sqlitedefid = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'sqlitedefid'};
			next if ($VLibDefinitions->{$sqlitedefid} || $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'vlibsource'} == 3);
			$log->debug("Deleting virtual matrix config with ID '$sqlitedefid' because its SQLite definition file no longer exists.");
			delete $virtuallibrariesmatrix->{$virtuallibrariesconfig};
			$prefs->set('virtuallibrariesmatrix', $virtuallibrariesmatrix);
		}

		# unregister SQLVL virtual libraries that are no longer part of the virtuallibrariesmatrix
		foreach my $thisVLrealID (keys %{$LMS_virtuallibraries}) {
			my $thisVLID = $LMS_virtuallibraries->{$thisVLrealID}->{'id'};
			$log->debug('VLID: '.$thisVLID.' - RealID: '.$thisVLrealID);
			if (starts_with($thisVLID, 'PLUGIN_SQLVL_VLID_') == 0) {
				my $VLisinBrowseMenusConfigMatrix = 0;
				foreach my $virtuallibrariesconfig (sort {lc($virtuallibrariesmatrix->{$a}->{browsemenu_name}) cmp lc($virtuallibrariesmatrix->{$b}->{browsemenu_name})} keys %{$virtuallibrariesmatrix}) {
					next if (!defined ($virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'enabled'}));
					my $sqlitedefid = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'sqlitedefid'};
					my $VLID;
					if (defined $sqlitedefid && ($sqlitedefid ne '')) {
						$VLID = 'PLUGIN_SQLVL_VLID_'.trim_all(uc($sqlitedefid));
					}
					if ($VLID eq $thisVLID) {
							$log->debug('VL \''.$VLID.'\' already exists and is still part of the virtuallibrariesmatrix. No need to unregister it.');
							$VLisinBrowseMenusConfigMatrix = 1;
					}
				}
				if ($VLisinBrowseMenusConfigMatrix == 0) {
					$log->debug('VL \''.$thisVLID.'\' is not part of the virtuallibrariesmatrix. Unregistering VL.');
					Slim::Music::VirtualLibraries->unregisterLibrary($thisVLrealID);
				}
			}
		}

		# create/register VLs that don't exist yet
		foreach my $virtuallibrariesconfig (sort {lc($virtuallibrariesmatrix->{$a}->{browsemenu_name}) cmp lc($virtuallibrariesmatrix->{$b}->{browsemenu_name})} keys %{$virtuallibrariesmatrix}) {
			my $enabled = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'enabled'};
			next if (!defined $enabled || $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'vlibsource'} == 3);
			my $sqlitedefid = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'sqlitedefid'};
			$log->debug('sqlitedefid = '.$sqlitedefid);
			my $browsemenu_name = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_name'};
			$log->debug('browsemenu_name = '.$browsemenu_name);
			my $VLID = 'PLUGIN_SQLVL_VLID_'.trim_all(uc($sqlitedefid));;
			$log->debug('VLID = '.$VLID);
			my $sql;
			if ($sqlitedefid eq 'compisrandom') {
				my $compisrandom_genreexcludelist = $prefs->get('compisrandom_genreexcludelist');
				if (defined $compisrandom_genreexcludelist && $compisrandom_genreexcludelist ne '') {
					my @genres = split /;;/, $compisrandom_genreexcludelist;
					map { s/^\s+|\s+$//g; } @genres;
					my $genreexcludelist = '';
					$genreexcludelist = join ',', map qq/'$_'/, @genres;
					$log->debug('compis random genre exclude list = '.$genreexcludelist);
					$sql = "insert or ignore into library_track (library, track) select '%s', tracks.id from tracks,albums left join comments comments on comments.track = tracks.id where albums.id=tracks.album and albums.compilation=1 and tracks.audio = 1 and not exists(select * from comments where comments.track=tracks.id and comments.value like '%%EoJ%%') and not exists(select * from genre_track,genres where genre_track.track=tracks.id and genre_track.genre=genres.id and genres.name in ($genreexcludelist)) group by tracks.id";
				} else {
					$sql = "insert or ignore into library_track (library, track) select '%s', tracks.id from tracks,albums where albums.id=tracks.album and albums.compilation=1 and tracks.audio = 1 group by tracks.id";
				}
			} else {
				$sql = $VLibDefinitions->{$sqlitedefid}->{'sql'};
			}
			$log->debug('sql = '.$sql);
			next if $sql eq 'menuonly';
			my $sqlstatement = qq{$sql};
			my $VLalreadyexists = Slim::Music::VirtualLibraries->getRealId($VLID);
			$log->debug('Check if VL already exists. Returned real library id = '.Dumper($VLalreadyexists));

			if (defined $VLalreadyexists) {
				$log->debug('VL \''.$VLID.'\' already exists. No need to recreate it.');
				if ($isPostScanCall == 1) {
					$log->debug('This is a post-scan call so let\'s refresh VL \''.$VLID.'\'.');
					Slim::Music::VirtualLibraries->rebuild($VLalreadyexists);
				}
				next;
			};
			$log->debug('VL \''.$VLID.'\' has not been created yet. Creating & registering it now.');

			my $library;
			$library = {
					id => $VLID,
					name => $browsemenu_name,
					sql => $sqlstatement,
			};

			$log->debug('Registering virtual library '.$VLID);
			eval {
				Slim::Music::VirtualLibraries->registerLibrary($library);
				Slim::Music::VirtualLibraries->rebuild($library->{id});
			};
			if ($@) {
				$log->error("Error registering library '".$library->{'name'}."'. Is SQLite statement valid? Error message: $@");
				Slim::Music::VirtualLibraries->unregisterLibrary($library->{id});
				next;
			};

			my $trackCount = Slim::Utils::Misc::delimitThousands(Slim::Music::VirtualLibraries->getTrackCount($VLID)) || 0;
			$log->debug("track count vlib '$browsemenu_name' = ".$trackCount);
			Slim::Music::VirtualLibraries->unregisterLibrary($library->{id}) if $trackCount == 0;

		}
		$isPostScanCall = 0;
	}

	my $ended = time() - $started;
	$log->info('Finished initializing virtual libraries after '.$ended.' secs.');
	initHomeVLMenus();
}

sub initHomeVLMenus {
	$log->debug('Started initializing HOME VL menus.');
	my $started = time();
	my $virtuallibrariesmatrix = $prefs->get('virtuallibrariesmatrix');

	if (keys %{$virtuallibrariesmatrix} > 0) {
		### get enabled browse menus for home menu
		my (@enabledWithHomeBrowseMenus, @enabledNotUserConfigurable);
		foreach my $thisconfig (keys %{$virtuallibrariesmatrix}) {
			if ($virtuallibrariesmatrix->{$thisconfig}->{'enabled'} && $virtuallibrariesmatrix->{$thisconfig}->{'homemenu'}) {
				if (defined($VLibDefinitions->{$virtuallibrariesmatrix->{$thisconfig}->{'sqlitedefid'}}->{'notuserconfigurable'})) {
					push @enabledNotUserConfigurable, $thisconfig;
				} elsif (($virtuallibrariesmatrix->{$thisconfig}->{'numberofenabledbrowsemenus'}+0) > 0) {
					push @enabledWithHomeBrowseMenus, $thisconfig;
				}
			}
		}
		$log->debug('enabled configs (not user-configurable) = '.scalar(@enabledNotUserConfigurable));
		$log->debug('enabled configs (for home menu) = '.scalar(@enabledWithHomeBrowseMenus));

		### create browse menus for home folder
		if (scalar @enabledWithHomeBrowseMenus > 0) {
			my @homeBrowseMenus = ();

			foreach my $virtuallibrariesconfig (sort @enabledWithHomeBrowseMenus) {
				my $enabled = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'enabled'};
				next if (!$enabled);
				my $sqlitedefid = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'sqlitedefid'};
				my $VLID;
				if ($virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'vlibsource'} == 3) {
					$VLID = $sqlitedefid;
				} else {
					$VLID = $VLibDefinitions->{$sqlitedefid}->{'vlid'};
				}
				$log->debug('VLID = '.Dumper($VLID));
				my $library_id = Slim::Music::VirtualLibraries->getRealId($VLID);
				next if (!$library_id);
				next if !($virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'homemenu'});
				my $menuWeight = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'menuweight'};

				if (defined $enabled && defined $library_id) {
					my $browsemenu_name = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_name'};
					$log->debug('browsemenu_name = '.$browsemenu_name);
					my $browsemenu_contributor_allartists = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_allartists'};
					my $browsemenu_contributor_albumartists = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_albumartists'};
					my $browsemenu_contributor_composers = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_composers'};
					my $browsemenu_contributor_conductors = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_conductors'};
					my $browsemenu_contributor_trackartists = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_trackartists'};
					my $browsemenu_contributor_bands = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_bands'};
					my $browsemenu_albums_all = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_albums_all'};
					my $browsemenu_albums_nocompis = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_albums_nocompis'};
					my $browsemenu_albums_compisonly = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_albums_compisonly'};
					my $browsemenu_genres = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_genres'};
					my $browsemenu_years = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_years'};
					my $browsemenu_tracks = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_tracks'};

					### ARTISTS MENUS ###

					# user configurable list of artists
					if (defined $browsemenu_contributor_allartists) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_MENUDISPLAYNAME_CONTIBUTOR_ALLARTISTS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/artists.png',
							jiveIcon => 'html/images/artists.png',
							id => $VLID.'_BROWSEMENU_ALLARTISTS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $menuWeight ? $menuWeight : 209,
							cache => 1,

							feed => \&Slim::Menu::BrowseLibrary::_artists,
							homeMenuText => $menuString,
							params => {library_id => $library_id}
						};
					}

					# Album artists
					if (defined $browsemenu_contributor_albumartists) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_CONTIBUTOR_ALBUMARTISTS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/artists.png',
							jiveIcon => 'html/images/artists.png',
							id => $VLID.'_BROWSEMENU_ALBUMARTISTS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $menuWeight ? $menuWeight + 1 : 210,
							cache => 1,

							feed => \&Slim::Menu::BrowseLibrary::_artists,
							homeMenuText => $menuString,
							params => {library_id => $library_id,
										role_id => 'ALBUMARTIST'}
						};
					}

					# Composers
					if (defined $browsemenu_contributor_composers) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_CONTIBUTOR_COMPOSERS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/artists.png',
							jiveIcon => 'html/images/artists.png',
							id => $VLID.'_BROWSEMENU_COMPOSERS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $menuWeight ? $menuWeight + 2 : 211,
							cache => 1,

							feed => \&Slim::Menu::BrowseLibrary::_artists,
							homeMenuText => $menuString,
							params => {library_id => $library_id,
										role_id => 'COMPOSER'}
						};
					}

					# Conductors
					if (defined $browsemenu_contributor_conductors) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_CONTIBUTOR_CONDUCTORS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/artists.png',
							jiveIcon => 'html/images/artists.png',
							id => $VLID.'_BROWSEMENU_CONDUCTORS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $menuWeight ? $menuWeight + 3 : 212,
							cache => 1,

							feed => \&Slim::Menu::BrowseLibrary::_artists,
							homeMenuText => $menuString,
							params => {library_id => $library_id,
										role_id => 'CONDUCTOR'}
						};
					}

					# Track Artists
					if (defined $browsemenu_contributor_trackartists) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_CONTIBUTOR_TRACKARTISTS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/artists.png',
							jiveIcon => 'html/images/artists.png',
							id => $VLID.'_BROWSEMENU_TRACKARTISTS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $menuWeight ? $menuWeight + 4 : 213,
							cache => 1,

							feed => \&Slim::Menu::BrowseLibrary::_artists,
							homeMenuText => $menuString,
							params => {library_id => $library_id,
										role_id => 'TRACKARTIST'}
						};
					}

					# Bands
					if (defined $browsemenu_contributor_bands) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_CONTIBUTOR_BANDS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/artists.png',
							jiveIcon => 'html/images/artists.png',
							id => $VLID.'_BROWSEMENU_BANDS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $menuWeight ? $menuWeight + 5 : 214,
							cache => 1,

							feed => \&Slim::Menu::BrowseLibrary::_artists,
							homeMenuText => $menuString,
							params => {library_id => $library_id,
										role_id => 'BAND'}
						};
					}

					### ALBUMS MENUS ###

					# All Albums
					if (defined $browsemenu_albums_all) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_MENUDISPLAYNAME_ALBUMS_ALL'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/albums.png',
							jiveIcon => 'html/images/albums.png',
							id => $VLID.'_BROWSEMENU_ALLALBUMS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $menuWeight ? $menuWeight + 6 : 215,
							cache => 1,

							feed => \&Slim::Menu::BrowseLibrary::_albums,
							homeMenuText => $menuString,
							params => {library_id => $library_id}
						};
					}

					# Albums without compilations
					if (defined $browsemenu_albums_nocompis) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_ALBUMS_NOCOMPIS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/albums.png',
							jiveIcon => 'html/images/albums.png',
							id => $VLID.'_BROWSEMENU_ALBUM_NOCOMPIS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $menuWeight ? $menuWeight + 7 : 216,
							cache => 1,

							feed => \&Slim::Menu::BrowseLibrary::_albums,
							homeMenuText => $menuString,
							params => {library_id => $library_id,
										compilation => '0 || null'}
						};
					}

					# Compilations only
					if (defined $browsemenu_albums_compisonly) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_ALBUMS_COMPIS_ONLY'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/albums.png',
							jiveIcon => 'html/images/albums.png',
							id => $VLID.'_BROWSEMENU_ALBUM_COMPISONLY',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $menuWeight ? $menuWeight + 8 : 217,
							cache => 1,

							feed => \&Slim::Menu::BrowseLibrary::_albums,
							homeMenuText => $menuString,
							params => {library_id => $library_id,
										mode => 'vaalbums',
										compilation => 1,
										artist_id => Slim::Schema->variousArtistsObject->id}
						};
					}

					# Genres menu
					if (defined $browsemenu_genres) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_GENRES'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/genres.png',
							jiveIcon => 'html/images/genres.png',
							id => $VLID.'_BROWSEMENU_GENRE_ALL',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $menuWeight ? $menuWeight + 9 : 218,
							cache => 1,

							feed => \&Slim::Menu::BrowseLibrary::_genres,
							homeMenuText => $menuString,
							params => {library_id => $library_id}
						};
					}

					# Years menu
					if (defined $browsemenu_years) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_YEARS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/years.png',
							jiveIcon => 'html/images/years.png',
							id => $VLID.'_BROWSEMENU_YEARS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $menuWeight ? $menuWeight + 10 : 219,
							cache => 1,

							feed => \&Slim::Menu::BrowseLibrary::_years,
							homeMenuText => $menuString,
							params => {library_id => $library_id}
						};
					}

					# Just Tracks Menu
					if (defined $browsemenu_tracks) {
						my $menuString = registerCustomString($browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_TRACKS'));
						push @homeBrowseMenus,{
							type => 'link',
							name => $menuString,
							icon => 'html/images/playlists.png',
							jiveIcon => 'html/images/playlists.png',
							id => $VLID.'_BROWSEMENU_TRACKS',
							condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
							weight => $menuWeight ? $menuWeight + 11 : 220,
							cache => 1,

							feed => \&Slim::Menu::BrowseLibrary::_tracks,
							homeMenuText => $menuString,
							params => {library_id => $library_id,
										sort => 'track',
										menuStyle => 'menuStyle:album'}
						};
					}
				}
			}
			if (scalar(@homeBrowseMenus) > 0) {
				foreach (@homeBrowseMenus) {
					Slim::Menu::BrowseLibrary->deregisterNode($_);
					Slim::Menu::BrowseLibrary->registerNode($_);
				}
			}
		}

		if (scalar @enabledNotUserConfigurable > 0) {
			my @notUserConfigurableHomeBrowseMenus = ();

			foreach my $virtuallibrariesconfig (sort @enabledNotUserConfigurable) {
				my $enabled = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'enabled'};
				next if (!$enabled);
				my $sqlitedefid = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'sqlitedefid'};
				my $VLID = $VLibDefinitions->{$sqlitedefid}->{'vlid'};
				$log->debug('VLID = '.$VLID);
				my $library_id = Slim::Music::VirtualLibraries->getRealId($VLID) if $VLID;

				# Compilations Random
				if ($sqlitedefid eq 'compisrandom') {
					push @notUserConfigurableHomeBrowseMenus,{
						type => 'link',
						name=> 'PLUGIN_SQLVL_MENUNAME_COMPISRANDOM',
						params=>{library_id => $library_id,
								mode => 'randomalbums',
								sort => 'random'},
						feed => \&Slim::Menu::BrowseLibrary::_albums,
						icon => 'plugins/SQLiteVirtualLibraries/html/images/randomcompis_svg.png',
						jiveIcon => 'plugins/SQLiteVirtualLibraries/html/images/randomcompis_svg.png',
						homeMenuText => 'PLUGIN_SQLVL_MENUNAME_COMPISRANDOM',
						condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
						id => 'PLUGIN_SQLVL_MENUID_COMPIS_RANDOM',
						weight => 25,
						cache => 0,
					};
				}

				# Compilations by Genre
				if ($sqlitedefid eq 'compisbygenre') {
					push @notUserConfigurableHomeBrowseMenus,{
						type => 'link',
						name => 'PLUGIN_SQLVL_MENUNAME_COMPISBYGENRE',
						params => {artist_id => Slim::Schema->variousArtistsObject->id,
									mode => 'genres',
									sort => 'title'},
						feed => \&Slim::Menu::BrowseLibrary::_genres,
						icon => 'plugins/SQLiteVirtualLibraries/html/images/compisbygenre_svg.png',
						jiveIcon => 'plugins/SQLiteVirtualLibraries/html/images/compisbygenre_svg.png',
						homeMenuText => 'PLUGIN_SQLVL_MENUNAME_COMPISBYGENRE',
						condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
						id => 'PLUGIN_SQLVL_MENUID_COMPIS_BYGENRE',
						weight => 26,
						cache => 1,
					};
				}
			}

			if (scalar(@notUserConfigurableHomeBrowseMenus) > 0) {
				foreach (@notUserConfigurableHomeBrowseMenus) {
					Slim::Menu::BrowseLibrary->deregisterNode($_);
					Slim::Menu::BrowseLibrary->registerNode($_);
				}
			}
		}

	my $ended = time() - $started;
	$log->info('Finished initializing home VL browse menus after '.$ended.' secs.');
	initCollectedVLMenus();
	}
}

sub initCollectedVLMenus {
	$log->debug('Started initializing collected VL menus.');
	my $started = time();
	my $virtuallibrariesmatrix = $prefs->get('virtuallibrariesmatrix');
	my $browsemenus_parentfolderID = 'PLUGIN_SQLVL_SQLVLPARENTFOLDER';
	my $browsemenus_parentfoldername = $prefs->get('browsemenus_parentfoldername');

	# deregister parent folder menu
	Slim::Menu::BrowseLibrary->deregisterNode($browsemenus_parentfolderID);
	my $nameToken = registerCustomString($browsemenus_parentfoldername);

	if (keys %{$virtuallibrariesmatrix} > 0) {
		### get enabled browse menus for SQLVL parent folder
		my @enabledWithCollectedBrowseMenus;
		foreach my $thisconfig (keys %{$virtuallibrariesmatrix}) {
			if (defined($virtuallibrariesmatrix->{$thisconfig}->{'enabled'}) && ($virtuallibrariesmatrix->{$thisconfig}->{'numberofenabledbrowsemenus'}+0) > 0) {
				unless (defined($virtuallibrariesmatrix->{$thisconfig}->{'homemenu'})) {
					push @enabledWithCollectedBrowseMenus, $thisconfig;
				}
			}
		}
		$log->debug('enabled configs (collected in SQLVL parent folder) = '.scalar(@enabledWithCollectedBrowseMenus));

		### create browse menus collected in SQLVL parent folder
		if (scalar @enabledWithCollectedBrowseMenus > 0) {
			my $browsemenus_parentfoldericon = $prefs->get('browsemenus_parentfoldericon');
			my $iconPath;
			if ($browsemenus_parentfoldericon == 1) {
				$iconPath = 'plugins/SQLiteVirtualLibraries/html/images/browsemenupfoldericon.png';
			} elsif ($browsemenus_parentfoldericon == 2) {
				$iconPath = 'plugins/SQLiteVirtualLibraries/html/images/folder_svg.png';
			} else {
				$iconPath = 'plugins/SQLiteVirtualLibraries/html/images/music_svg.png';
			}
			$log->debug('browsemenus_parentfoldericon = '.$browsemenus_parentfoldericon);
			$log->debug('iconPath = '.$iconPath);

			Slim::Menu::BrowseLibrary->registerNode({
				type => 'link',
				name => $nameToken,
				id => $browsemenus_parentfolderID,
				feed => sub {
					my ($client, $cb, $args, $pt) = @_;
					my @collectedBrowseMenus = ();
					foreach my $virtuallibrariesconfig (sort @enabledWithCollectedBrowseMenus) {
						my $enabled = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'enabled'};
						next if (!$enabled);
						my $sqlitedefid = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'sqlitedefid'};
						my $VLID;
						if ($virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'vlibsource'} == 3) {
							$VLID = $sqlitedefid;
						} else {
							$VLID = $VLibDefinitions->{$sqlitedefid}->{'vlid'};
						}
						$log->debug('VLID = '.$VLID);
						my $library_id = Slim::Music::VirtualLibraries->getRealId($VLID);
						next if (!$library_id);
						next if $VLibDefinitions->{$virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'sqlitedefid'}}->{'homemenu'};

						if (defined $enabled && defined $library_id) {
							my $pt = {library_id => $library_id};
							my $browsemenu_name = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_name'};
							$log->debug('browsemenu_name = '.$browsemenu_name);
							my $browsemenu_contributor_allartists = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_allartists'};
							my $browsemenu_contributor_albumartists = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_albumartists'};
							my $browsemenu_contributor_composers = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_composers'};
							my $browsemenu_contributor_conductors = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_conductors'};
							my $browsemenu_contributor_trackartists = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_trackartists'};
							my $browsemenu_contributor_bands = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_bands'};
							my $browsemenu_albums_all = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_albums_all'};
							my $browsemenu_albums_nocompis = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_albums_nocompis'};
							my $browsemenu_albums_compisonly = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_albums_compisonly'};
							my $browsemenu_genres = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_genres'};
							my $browsemenu_years = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_years'};
							my $browsemenu_tracks = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_tracks'};

							### ARTISTS MENUS ###

							# user configurable list of artists
							if (defined $browsemenu_contributor_allartists) {
								push @collectedBrowseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_MENUDISPLAYNAME_CONTIBUTOR_ALLARTISTS'),
									icon => 'html/images/artists.png',
									jiveIcon => 'html/images/artists.png',
									id => $VLID.'_BROWSEMENU_ALLARTISTS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 209,
									cache => 1,
									url => \&Slim::Menu::BrowseLibrary::_artists,
									passthrough => [{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'},
											#'role_id:'.join ',', Slim::Schema::Contributor->contributorRoles()
										],
									}],
								};
							}

							# Album artists
							if (defined $browsemenu_contributor_albumartists) {
								push @collectedBrowseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_CONTIBUTOR_ALBUMARTISTS'),
									icon => 'html/images/artists.png',
									jiveIcon => 'html/images/artists.png',
									id => $VLID.'_BROWSEMENU_ALBUMARTISTS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 210,
									cache => 1,
									url => \&Slim::Menu::BrowseLibrary::_artists,
									passthrough => [{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'},
											'role_id:ALBUMARTIST'
										],
									}],
								};
							}

							# Composers
							if (defined $browsemenu_contributor_composers) {
								push @collectedBrowseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_CONTIBUTOR_COMPOSERS'),
									icon => 'html/images/artists.png',
									jiveIcon => 'html/images/artists.png',
									id => $VLID.'_BROWSEMENU_COMPOSERS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 211,
									cache => 1,
									url => \&Slim::Menu::BrowseLibrary::_artists,
									passthrough => [{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'},
											'role_id:COMPOSER'
										],
									}],
								};
							}

							# Conductors
							if (defined $browsemenu_contributor_conductors) {
								push @collectedBrowseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_CONTIBUTOR_CONDUCTORS'),
									icon => 'html/images/artists.png',
									jiveIcon => 'html/images/artists.png',
									id => $VLID.'_BROWSEMENU_CONDUCTORS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 212,
									cache => 1,
									url => \&Slim::Menu::BrowseLibrary::_artists,
									passthrough => [{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'},
											'role_id:CONDUCTOR'
										],
									}],
								};
							}

							# Track Artists
							if (defined $browsemenu_contributor_trackartists) {
								push @collectedBrowseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_CONTIBUTOR_TRACKARTISTS'),
									icon => 'html/images/artists.png',
									jiveIcon => 'html/images/artists.png',
									id => $VLID.'_BROWSEMENU_TRACKARTISTS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 213,
									cache => 1,
									url => \&Slim::Menu::BrowseLibrary::_artists,
									passthrough => [{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'},
											'role_id:TRACKARTIST'
										],
									}],
								};
							}

							# Bands
							if (defined $browsemenu_contributor_bands) {
								push @collectedBrowseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_CONTIBUTOR_BANDS'),
									icon => 'html/images/artists.png',
									jiveIcon => 'html/images/artists.png',
									id => $VLID.'_BROWSEMENU_BANDS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 214,
									cache => 1,
									url => \&Slim::Menu::BrowseLibrary::_artists,
									passthrough => [{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'},
											'role_id:BAND'
										],
									}],
								};
							}

							### ALBUMS MENUS ###

							# All Albums
							if (defined $browsemenu_albums_all) {
								push @collectedBrowseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_MENUDISPLAYNAME_ALBUMS_ALL'),
									icon => 'html/images/albums.png',
									jiveIcon => 'html/images/albums.png',
									id => $VLID.'_BROWSEMENU_ALLALBUMS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 215,
									cache => 1,
									url => \&Slim::Menu::BrowseLibrary::_albums,
									passthrough => [{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'}
										],
									}],
								};
							}

							# Albums without compilations
							if (defined $browsemenu_albums_nocompis) {
								push @collectedBrowseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_ALBUMS_NOCOMPIS'),
									icon => 'html/images/albums.png',
									jiveIcon => 'html/images/albums.png',
									id => $VLID.'_BROWSEMENU_ALBUM_NOCOMPIS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 216,
									cache => 1,
									url => \&Slim::Menu::BrowseLibrary::_albums,
									passthrough => [{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'},
											'compilation: 0 || null'
										],
									}],
								};
							}

							# Compilations only
							if (defined $browsemenu_albums_compisonly) {
								$pt = {library_id => Slim::Music::VirtualLibraries->getRealId($VLID),
										artist_id => Slim::Schema->variousArtistsObject->id,
								};
								push @collectedBrowseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_ALBUMS_COMPIS_ONLY'),
									mode => 'vaalbums',
									icon => 'html/images/albums.png',
									jiveIcon => 'html/images/albums.png',
									id => $VLID.'_BROWSEMENU_ALBUM_COMPISONLY',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 217,
									cache => 1,
									url => \&Slim::Menu::BrowseLibrary::_albums,
									passthrough => [{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'},
											'artist_id:'.$pt->{'artist_id'},
											'compilation: 1'
										],
									}],
								};
							}

							# Genres menu
							if (defined $browsemenu_genres) {
								push @collectedBrowseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_GENRES'),
									icon => 'html/images/genres.png',
									jiveIcon => 'html/images/genres.png',
									id => $VLID.'_BROWSEMENU_GENRE_ALL',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 218,
									cache => 1,
									url => \&Slim::Menu::BrowseLibrary::_genres,
									passthrough => [{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'}
										],
									}],
								};
							}

							# Years menu
							if (defined $browsemenu_years) {
								push @collectedBrowseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_YEARS'),
									icon => 'html/images/years.png',
									jiveIcon => 'html/images/years.png',
									id => $VLID.'_BROWSEMENU_YEARS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 219,
									cache => 1,
									url => \&Slim::Menu::BrowseLibrary::_years,
									passthrough => [{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'}
										],
									}],
								};
							}

							# Just Tracks Menu
							if (defined $browsemenu_tracks) {
								$pt = {library_id => Slim::Music::VirtualLibraries->getRealId($VLID),
										sort => 'track',
										menuStyle => 'menuStyle:album'};
								push @collectedBrowseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_TRACKS'),
									icon => 'html/images/playlists.png',
									jiveIcon => 'html/images/playlists.png',
									id => $VLID.'_BROWSEMENU_TRACKS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 220,
									cache => 1,
									url => \&Slim::Menu::BrowseLibrary::_tracks,
									passthrough => [{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'}
										],
									}],
								};
							}
						}
					}

					$cb->({
						items => \@collectedBrowseMenus,
					});
				},
				weight => 99,
				cache => 0,
				icon => $iconPath,
				jiveIcon => $iconPath,
			});
		}
	my $ended = time() - $started;
	$log->info('Finished initializing collected VL browse menus after '.$ended.' secs.');
	}
}

sub deregAllMenus {
	my $nodeList = Slim::Menu::BrowseLibrary->_getNodeList();
	$log->debug('node list = '.Dumper($nodeList));

	foreach my $homeMenuItem (@{$nodeList}) {
		if (starts_with($homeMenuItem->{'name'}, 'PLUGIN_SQLVL_') == 0) {
			$log->debug('Deregistering home menu item: '.Dumper($homeMenuItem->{'id'}));
			Slim::Menu::BrowseLibrary->deregisterNode($homeMenuItem->{'id'});
		}
	}
}

sub initVirtualLibrariesDelayed {
	$log->debug('Delayed VL init to prevent multiple inits');
	$log->debug('Killing existing VL init timers');
	Slim::Utils::Timers::killOneTimer(undef, \&initVirtualLibraries);
	$log->debug('Scheduling a delayed VL init');
	Slim::Utils::Timers::setTimer(undef, time() + 3, \&initVirtualLibraries);
}

# read + parse virtual library SQLite definitions ##
sub getVirtualLibraryDefinitions {
	my $client = shift;
	my $pluginVLibDefFolder = $prefs->get('pluginvlibdeffolder');
	my $sqlcustomvldefdir = $prefs->get('sqlcustomvldefdir');

	my @localDefDirs = ($pluginVLibDefFolder, $sqlcustomvldefdir);
	$log->debug('Searching for Virtual Library SQLite definitions in local directories');

	for my $localDefDir (@localDefDirs) {
		if (!defined $localDefDir || !-d $localDefDir) {
			$log->debug("Skipping scan for Virtual Library SQLite definitions - directory '$localDefDir' is undefined or does not exist");
		} else {
			$log->debug('Checking dir: '.$localDefDir);
			my @dircontents = Slim::Utils::Misc::readDirectory($localDefDir, 'sql.xml', 'dorecursive');
			my $fileExtension = "\\.sql\\.xml\$";

			for my $item (@dircontents) {
				next unless $item =~ /$fileExtension/;
				next if -d $item;
				my $content = eval {read_file($item)};
				$item = basename($item);
				if ($content) {
					# If necessary convert the file data to utf8
					my $encoding = Slim::Utils::Unicode::encodingFromString($content);
					if ($encoding ne 'utf8') {
						$content = Slim::Utils::Unicode::latin1toUTF8($content);
						$content = Slim::Utils::Unicode::utf8on($content);
						$log->debug("Loading $item and converting from latin1");
					} else {
						$content = Slim::Utils::Unicode::utf8decode($content,'utf8');
						$log->debug("Loading $item without conversion with encoding ".$encoding);
					}

					my $parsedContent = parseContent($client, $item, $content);
					# source of virtual library: 1 = built-in, 2 = custom/user-provided, 3 = external
					$parsedContent->{'vlibsource'} = $localDefDir eq $pluginVLibDefFolder ? 1 : 2;
					$VLibDefinitions->{$parsedContent->{'id'}} = $parsedContent;
				}
			}
		}
	}
	$log->debug('VLib SQLite Definitions = '.Dumper($VLibDefinitions));
}

sub parseContent {
	my $client = shift;
	my $item = shift;
	my $content = shift;
	my $items = shift;

	if ($content) {
		decode_entities($content);

		my @VLibDataArray = split(/[\n\r]+/, $content);
		my $name = undef;
		my $notUserConfigurable = undef;
		my $menuOnlyNoSQL = undef;
		my $statement = '';
		my $fulltext = '';
		for my $line (@VLibDataArray) {
			if (!$name) {
				$name = parseVLibName($line);
				if (!$name) {
					my $file = $item;
					my $fileExtension = "\\.sql\\.xml\$";
					$item =~ s{$fileExtension$}{};
					$name = $item;
				}
			}
			$line .= "\n";
			if ($name) {
				$fulltext .= $line;
			}
			chomp $line;

			my $notuserconfig = parseUserConfigurable($line);
			my $menuonly =parseMenuOnly($line);

			$line =~ s/\s*--.*?$//o;
			$line =~ s/^\s*//o;

			$notUserConfigurable = 1 if $notuserconfig;
			$menuOnlyNoSQL = 1 if $menuonly;

			next if $line =~ /^--/;
			next if $line =~ /^\s*$/;


			if ($name) {
				$line =~ s/\s+$//;
				if ($statement) {
					if ($statement =~ /;$/) {
						$statement .= "\n";
					} else {
						$statement .= " ";
					}
				}
				$statement .= $line;
			}
		}
		$statement = 'menuonly' if $menuOnlyNoSQL;

		if ($name && $statement) {
			my $file = $item;
			my $fileExtension = "\\.sql\\.xml\$";
			$item =~ s{$fileExtension$}{};
			$name =~ s/\'\'/\'/g;
			my $virtuallibraryid = 'PLUGIN_SQLVL_VLID_'.trim_all(uc($item));

			my %virtuallibrary = (
				'id' => $item,
				'vlid' => $virtuallibraryid,
				'file' => $file,
				'name' => $name,
				'notuserconfigurable' => $notUserConfigurable,
				'sql' => Slim::Utils::Unicode::utf8decode($statement,'utf8'),
				'fulltext' => Slim::Utils::Unicode::utf8decode($fulltext,'utf8')
			);

			return \%virtuallibrary;
		}
	} else {
		my $errorMsg = "Unable to read virtuallibrary definition '$item'";
		$errorMsg .= ": $@" if $@;
		$log->warn($errorMsg);
	}
	return undef;
}

sub parseVLibName {
	my $line = shift;
	if ($line =~ /^\s*--\s*VirtualLibraryName\s*[:=]\s*/) {
		my $name = $line;
		$name =~ s/^\s*--\s*VirtualLibraryName\s*[:=]\s*//io;
		$name =~ s/\s+$//;
		$name =~ s/^\s+//;
		if ($name) {
			return $name;
		} else {
			$log->debug("No name found in: $line");
			$log->debug("Value: name = $name");
			return undef;
		}
	}
	return undef;
}

sub parseUserConfigurable {
	my $line = shift;
	if ($line =~ /^\s*--\s*NotUserConfigurable\s*/) {
		my $notUserConfigurable = $line;
		$notUserConfigurable =~ s/^\s*--\s*NotUserConfigurable\s*[:=]\s*//io;
		$notUserConfigurable =~ s/\s+$//;
		$notUserConfigurable =~ s/^\s+//;
		if ($notUserConfigurable) {
			return 1;
		} else {
			$log->debug("No NotUserConfigurable found in: $line");
			$log->debug("Value: NotUserConfigurable = $notUserConfigurable");
			return undef;
		}
	}
	return undef;
}

sub parseMenuOnly {
	my $line = shift;
	if ($line =~ /^\s*--\s*MenuOnly\s*/) {
		my $menuOnly = $line;
		$menuOnly =~ s/^\s*--\s*MenuOnly\s*[:=]\s*//io;
		$menuOnly =~ s/\s+$//;
		$menuOnly =~ s/^\s+//;
		if ($menuOnly) {
			return 1;
		} else {
			$log->debug("No MenuOnly found in: $line");
			$log->debug("Value: MenuOnly = $menuOnly");
			return undef;
		}
	}
	return undef;
}


sub getVLibDefList {
	$VLibDefinitions = {};
	getVirtualLibraryDefinitions();
	return \%{$VLibDefinitions};
}

sub createCustomVLdefDir {
	my $sqlcustomvldefdir_parentfolderpath = $prefs->get('sqlcustomvldefdir_parentfolderpath') || $serverPrefs->get('playlistdir');
	my $sqlcustomvldefdir = catfile($sqlcustomvldefdir_parentfolderpath, 'SQLVL-VirtualLibrary-definitions');
	eval {
		mkdir($sqlcustomvldefdir, 0755) unless (-d $sqlcustomvldefdir);
		chdir($sqlcustomvldefdir);
	} or do {
		$log->error("Could not create or access custom vl directory in parent folder '$sqlcustomvldefdir_parentfolderpath'");
		return;
	};
	$prefs->set('sqlcustomvldefdir', $sqlcustomvldefdir);
}

sub registerCustomString {
	my $string = shift;
	if (!Slim::Utils::Strings::stringExists($string)) {
		my $token = uc(Slim::Utils::Text::ignoreCase($string, 1));
		$token =~ s/\s/_/g;
		$token = 'PLUGIN_SQLVL_BROWSEMENUS_' . $token;
		Slim::Utils::Strings::storeExtraStrings([{
			strings => {EN => $string},
			token => $token,
		}]) if !Slim::Utils::Strings::stringExists($token);
		return $token;
	}
	return $string;
}

sub trim_leadtail {
	my ($str) = @_;
	$str =~ s{^\s+}{};
	$str =~ s{\s+$}{};
	return $str;
}

sub trim_all {
	my ($str) = @_;
	$str =~ s/ //g;
	return $str;
}

sub starts_with {
	# complete_string, start_string, position
	return rindex($_[0], $_[1], 0);
	# returns 0 for yes, -1 for no
}

sub getCurrentDBH {
	return Slim::Schema->storage->dbh();
}

1;
