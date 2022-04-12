#					SQLiteVirtualLibraries plugin
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
use Data::Dumper;
use Time::HiRes qw(time);

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
		sqldefdirparentfolderpath => $serverPrefs->get('playlistdir'),
		browsemenus_parentfoldername => 'My VL Menus',
		browsemenus_parentfoldericon => 1,
	});
	my $sqldefdir_parentfolderpath = $prefs->get('sqldefdirparentfolderpath') || $serverPrefs->get('playlistdir');
	my $sqldefdir = $sqldefdir_parentfolderpath.'/SVLS-VirtualLibrary-definitions';
	mkdir($sqldefdir, 0755) unless (-d $sqldefdir);

	$prefs->setValidate('dir', 'sqldefdirparentfolderpath');
	$prefs->setChange(sub {
		my $sqldefdir_parentfolderpath = $prefs->get('sqldefdirparentfolderpath');
		my $sqldefdir = $sqldefdir_parentfolderpath.'/SVLS-VirtualLibrary-definitions';
		mkdir($sqldefdir, 0755) unless (-d $sqldefdir);
		}, 'sqldefdirparentfolderpath');

	$prefs->setValidate({
		validator => sub {
			if (defined $_[1] && $_[1] ne '') {
				return if $_[1] =~ m|[\^{}$@<>"#%?*:/\|\\]|;
				return if $_[1] =~ m|.{61,}|;
			}
			return 1;
		}
	}, 'browsemenus_parentfoldername');
	$prefs->setChange(sub {
			$log->debug('Change in VL config changed. Reinitializing VLs + menus.');
			initVirtualLibrariesDelayed();
		}, 'virtuallibrariesmatrix');
	$prefs->setChange(sub {
			$log->debug('Change in VL menus config changed. Reinitializing VL menus.');
			initVLMenus();
		}, 'browsemenus_parentfoldername', 'browsemenus_parentfoldericon');
}

sub postinitPlugin {
	unless (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		initVirtualLibrariesDelayed();
	}
}

sub initVirtualLibraries {
	$log->debug('Start initializing VLs.');

	## update list of available virtual library SQLite definitions in folder
	getVirtualLibraryDefinitions();

	## check if VLs are globally disabled
	if (defined ($prefs->get('vlstempdisabled'))) {
		# unregister VLs
		$log->debug('VLs globally disabled. Unregistering SVLS VLs.');
		my $libraries = Slim::Music::VirtualLibraries->getLibraries();
		foreach my $thisVLrealID (keys %{$libraries}) {
			my $thisVLID = $libraries->{$thisVLrealID}->{'id'};
			$log->debug('VLID: '.$thisVLID.' - RealID: '.$thisVLrealID);
			if (starts_with($thisVLID, 'SVLS_VLID_') == 0) {
				Slim::Music::VirtualLibraries->unregisterLibrary($thisVLrealID);
			}
		}

		# unregister menus
		$log->debug('VLs globally disabled. Deregistering SVLS menus.');
		Slim::Menu::BrowseLibrary->deregisterNode('SVLS_MYCUSTOMMENUS');

		return;
	}

	my $started = time();
	my $virtuallibrariesmatrix = $prefs->get('virtuallibrariesmatrix');
	$log->debug('virtuallibrariesmatrix = '.Dumper($virtuallibrariesmatrix));

	### create/register VLs

	if (keys %{$virtuallibrariesmatrix} > 0) {

		# unregister SVLS virtual libraries that are no longer part of the virtuallibrariesmatrix

		my $libraries = Slim::Music::VirtualLibraries->getLibraries();
		$log->debug('Found these virtual libraries: '.Dumper($libraries));

		foreach my $thisVLrealID (keys %{$libraries}) {
			my $thisVLID = $libraries->{$thisVLrealID}->{'id'};
			$log->debug('VLID: '.$thisVLID.' - RealID: '.$thisVLrealID);
			if (starts_with($thisVLID, 'SVLS_VLID_') == 0) {
				my $VLisinBrowseMenusConfigMatrix = 0;
				foreach my $virtuallibrariesconfig (sort {lc($virtuallibrariesmatrix->{$a}->{browsemenu_name}) cmp lc($virtuallibrariesmatrix->{$b}->{browsemenu_name})} keys %{$virtuallibrariesmatrix}) {
					next if (!defined ($virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'enabled'}));
					my $sqlitedefid = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'sqlitedefid'};
					my $VLID;
					if (defined $sqlitedefid && ($sqlitedefid ne '')) {
						$VLID = 'SVLS_VLID_'.trim_all(uc($sqlitedefid));
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
			next if (!defined $enabled);
			my $sqlitedefid = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'sqlitedefid'};
			$log->debug('sqlitedefid = '.$sqlitedefid);
			my $browsemenu_name = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_name'};
			$log->debug('browsemenu_name = '.$browsemenu_name);
			my $VLID = 'SVLS_VLID_'.trim_all(uc($sqlitedefid));;
			$log->debug('VLID = '.$VLID);
			my $sql = $VLibDefinitions->{$sqlitedefid}->{'sql'};
			$log->debug('sql = '.$sql);
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
			Slim::Music::VirtualLibraries->registerLibrary($library);
			Slim::Music::VirtualLibraries->rebuild($library->{id});


			my $trackCount = Slim::Utils::Misc::delimitThousands(Slim::Music::VirtualLibraries->getTrackCount($VLID)) || 0;
			$log->debug("track count vlib '$browsemenu_name' = ".$trackCount);
			Slim::Music::VirtualLibraries->unregisterLibrary($library->{id}) if $trackCount == 0;

		}
		$isPostScanCall = 0;
	}

	my $ended = time() - $started;
	initVLMenus();
}

sub initVLMenus {
	$log->debug('Started initializing VL menus.');
	my $virtuallibrariesmatrix = $prefs->get('virtuallibrariesmatrix');
	my $browsemenus_parentfolderID = 'SVLS_MYCUSTOMMENUS';
	my $browsemenus_parentfoldername = $prefs->get('browsemenus_parentfoldername');

	# deregister parent folder menu
	Slim::Menu::BrowseLibrary->deregisterNode($browsemenus_parentfolderID);
	my $nameToken = registerCustomString($browsemenus_parentfoldername);

	if (keys %{$virtuallibrariesmatrix} > 0) {
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

		my @enabledbrowsemenus;
		foreach my $thisconfig (keys %{$virtuallibrariesmatrix}) {
			if (defined $virtuallibrariesmatrix->{$thisconfig}->{'enabled'} && ($virtuallibrariesmatrix->{$thisconfig}->{'numberofenabledbrowsemenus'}+0) > 0) {
				push @enabledbrowsemenus, $thisconfig;
			}
		}
		$log->debug('enabled configs = '.scalar(@enabledbrowsemenus));

		### browse menus in SVLS parent folder (custom browse menus)

		if (scalar (@enabledbrowsemenus) > 0) {
			Slim::Menu::BrowseLibrary->registerNode({
				type => 'link',
				name => $nameToken,
				id => $browsemenus_parentfolderID,
				feed => sub {
					my ($client, $cb, $args, $pt) = @_;
					my @browseMenus = ();

					foreach my $virtuallibrariesconfig (sort {lc($virtuallibrariesmatrix->{$a}->{browsemenu_name}) cmp lc($virtuallibrariesmatrix->{$b}->{browsemenu_name})} keys %{$virtuallibrariesmatrix}) {
						my $enabled = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'enabled'};
						next if (!$enabled);
						my $sqlitedefid = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'sqlitedefid'};
						my $VLID = $VLibDefinitions->{$sqlitedefid}->{'vlid'};
						$log->debug('VLID = '.$VLID);
						my $library_id = Slim::Music::VirtualLibraries->getRealId($VLID);
						next if (!$library_id);

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
								push @browseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_MENUDISPLAYNAME_CONTIBUTOR_ALLARTISTS'),
									url => \&Slim::Menu::BrowseLibrary::_artists,
									icon => 'html/images/artists.png',
									jiveIcon => 'html/images/artists.png',
									id => $VLID.'_BROWSEMENU_ALLARTISTS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 209,
									cache => 1,
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
								push @browseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_CONTIBUTOR_ALBUMARTISTS'),
									url => \&Slim::Menu::BrowseLibrary::_artists,
									icon => 'html/images/artists.png',
									jiveIcon => 'html/images/artists.png',
									id => $VLID.'_BROWSEMENU_ALBUMARTISTS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 210,
									cache => 1,
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
								push @browseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_CONTIBUTOR_COMPOSERS'),
									url => \&Slim::Menu::BrowseLibrary::_artists,
									icon => 'html/images/artists.png',
									jiveIcon => 'html/images/artists.png',
									id => $VLID.'_BROWSEMENU_COMPOSERS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 211,
									cache => 1,
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
								push @browseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_CONTIBUTOR_CONDUCTORS'),
									url => \&Slim::Menu::BrowseLibrary::_artists,
									icon => 'html/images/artists.png',
									jiveIcon => 'html/images/artists.png',
									id => $VLID.'_BROWSEMENU_CONDUCTORS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 212,
									cache => 1,
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
								push @browseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_CONTIBUTOR_TRACKARTISTS'),
									url => \&Slim::Menu::BrowseLibrary::_artists,
									icon => 'html/images/artists.png',
									jiveIcon => 'html/images/artists.png',
									id => $VLID.'_BROWSEMENU_TRACKARTISTS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 213,
									cache => 1,
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
								push @browseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_CONTIBUTOR_BANDS'),
									url => \&Slim::Menu::BrowseLibrary::_artists,
									icon => 'html/images/artists.png',
									jiveIcon => 'html/images/artists.png',
									id => $VLID.'_BROWSEMENU_BANDS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 214,
									cache => 1,
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
								push @browseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_MENUDISPLAYNAME_ALBUMS_ALL'),
									url => \&Slim::Menu::BrowseLibrary::_albums,
									icon => 'html/images/albums.png',
									jiveIcon => 'html/images/albums.png',
									id => $VLID.'_BROWSEMENU_ALLALBUMS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 215,
									cache => 1,
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
								push @browseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_ALBUMS_NOCOMPIS'),
									url => \&Slim::Menu::BrowseLibrary::_albums,
									icon => 'html/images/albums.png',
									jiveIcon => 'html/images/albums.png',
									id => $VLID.'_BROWSEMENU_ALBUM_NOCOMPIS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 216,
									cache => 1,
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
								push @browseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_ALBUMS_COMPIS_ONLY'),
									mode => 'vaalbums',
									url => \&Slim::Menu::BrowseLibrary::_albums,
									icon => 'html/images/albums.png',
									jiveIcon => 'html/images/albums.png',
									id => $VLID.'_BROWSEMENU_ALBUM_COMPISONLY',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 217,
									cache => 1,
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
								push @browseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_GENRES'),
									url => \&Slim::Menu::BrowseLibrary::_genres,
									icon => 'html/images/genres.png',
									jiveIcon => 'html/images/genres.png',
									id => $VLID.'_BROWSEMENU_GENRE_ALL',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 218,
									cache => 1,
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
								push @browseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_YEARS'),
									url => \&Slim::Menu::BrowseLibrary::_years,
									icon => 'html/images/years.png',
									jiveIcon => 'html/images/years.png',
									id => $VLID.'_BROWSEMENU_YEARS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 219,
									cache => 1,
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
								push @browseMenus,{
									type => 'link',
									name => $browsemenu_name.' - '.string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_BROWSEMENUS_TRACKS'),
									url => \&Slim::Menu::BrowseLibrary::_tracks,
									icon => 'html/images/playlists.png',
									jiveIcon => 'html/images/playlists.png',
									id => $VLID.'_BROWSEMENU_TRACKS',
									condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
									weight => 220,
									cache => 1,
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
						items => \@browseMenus,
					});
				},
				weight => 99,
				cache => 0,
				icon => $iconPath,
				jiveIcon => $iconPath,
			});
		}
	}

	$log->debug('Finished initializing VL menus');
}

sub initVirtualLibrariesDelayed {
	$log->debug('Delayed VL init to prevent multiple inits');
	$log->debug('Killing existing VL init timers');
	Slim::Utils::Timers::killOneTimer(undef, \&initVirtualLibraries);
	$log->debug('Scheduling a delayed VL init');
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 3, \&initVirtualLibraries);
}

sub initExtraMenusDelayed {
	$log->debug('Delayed extra menus init invoked to prevent multiple inits');
	$log->debug('Killing existing timers');
	Slim::Utils::Timers::killOneTimer(undef, \&initExtraMenus);
	$log->debug('Scheduling a delayed extra menus init');
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 2, \&initExtraMenus);
}

# read + parse virtual library SQLite definitions ##
sub getVirtualLibraryDefinitions {
	my $client = shift;
	my $sqldefdir_parentfolderpath = $prefs->get('sqldefdirparentfolderpath');
	my $sqldefdir = $sqldefdir_parentfolderpath.'/SVLS-VirtualLibrary-definitions';
	mkdir($sqldefdir, 0755) unless (-d $sqldefdir);
	chdir($sqldefdir) or $sqldefdir = $sqldefdir_parentfolderpath;

	if (!$sqldefdir) {
		$log->error('Folder for Virtual Library SQLite definitions is undefined or does not exist.');
	}
	$log->debug("Searching for Virtual Library SQLite definitions in folder '".$sqldefdir."'");
	my @dircontents = Slim::Utils::Misc::readDirectory($sqldefdir, 'sql.xml', 'dorecursive');
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
			$VLibDefinitions->{$parsedContent->{'id'}} = $parsedContent;
		}
	}
	$log->debug('VLib SQLite Definitions = '.Dumper($VLibDefinitions));
}

sub parseContent {
	my $client = shift;
	my $item = shift;
	my $content = shift;
	my $items = shift;

	my $errorMsg = undef;
	if ($content) {
		decode_entities($content);

		my @VLibDataArray = split(/[\n\r]+/, $content);
		my $name = undef;
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

			$line =~ s/\s*--.*?$//o;
			$line =~ s/^\s*//o;

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

		if ($name && $statement) {
			#my $virtuallibraryid = escape($name,"^A-Za-z0-9\-_");
			my $file = $item;
			my $fileExtension = "\\.sql\\.xml\$";
			$item =~ s{$fileExtension$}{};
			$name =~ s/\'\'/\'/g;
			my $virtuallibraryid = 'SVLS_VLID_'.trim_all(uc($item));

			my %virtuallibrary = (
				'id' => $item,
				'vlid' => $virtuallibraryid,
				'file' => $file,
				'name' => $name,
				'sql' => Slim::Utils::Unicode::utf8decode($statement,'utf8'),
				'fulltext' => Slim::Utils::Unicode::utf8decode($fulltext,'utf8')
			);

			return \%virtuallibrary;
		}
	} else {
		if ($@) {
			$errorMsg = "Incorrect information in virtuallibrary data: $@";
			$log->warn("Unable to read virtuallibrary configuration:\n$@");
		} else {
			$errorMsg = 'Incorrect information in virtuallibrary data';
			$log->warn('Unable to to read virtuallibrary configuration');
		}
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

sub getVLibDefList {
		return \%{$VLibDefinitions};
}

sub registerCustomString {
	my $string = shift;
	if (!Slim::Utils::Strings::stringExists($string)) {
		my $token = uc(Slim::Utils::Text::ignoreCase($string, 1));
		$token =~ s/\s/_/g;
		$token = 'PLUGIN_UCTI_BROWSEMENUS_' . $token;
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
