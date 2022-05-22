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

package Plugins::SQLiteVirtualLibraries::Settings;

use strict;
use warnings;
use utf8;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings;
use Slim::Utils::Strings qw(string cstring);
use Data::Dumper;

my $log = logger('plugin.sqlitevirtuallibraries');
my $prefs = preferences('plugin.sqlitevirtuallibraries');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SQLITEVIRTUALLIBRARIES');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/SQLiteVirtualLibraries/settings/settings.html');
}

sub prefs {
	return ($prefs, qw(vlstempdisabled browsemenus_parentfoldername browsemenus_parentfoldericon sqlcustomvldefdir_parentfolderpath compisrandom_genreexcludelist));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $maxItemNum = 40;

	if ($paramRef->{saveSettings}) {
		my %virtuallibrariesmatrix = ();
		my $VLibDefList = Plugins::SQLiteVirtualLibraries::Plugin::getVLibDefList();
		my %sqlitedefDone;
		my %browsemenu_nameDone;

		for (my $n = 0; $n <= $maxItemNum; $n++) {
			my $num_menus_enabled = 0;
			my $virtuallibrariesconfigID = $paramRef->{"pref_idNum_$n"};
			$log->debug('virtuallibrariesconfigID = '.Dumper($virtuallibrariesconfigID));
			next if (!defined $virtuallibrariesconfigID);
			my $enabled = $paramRef->{"pref_enabled_$n"} // undef;
			my $sqlitedefid = $paramRef->{"pref_sqlitedefid_$n"} // undef;
			$log->debug('sqlitedefid = '.Dumper($sqlitedefid));
			next if (!$sqlitedefid || ($sqlitedefid eq '') || ($sqlitedefid eq 'none'));
			my $browsemenu_name = trim_leadtail($paramRef->{"pref_browsemenu_name_$n"} // '');
			if (($browsemenu_name eq '') || ($browsemenu_name =~ m|[\^{}$@<>"#%?*:/\|\\]|)) {
				$browsemenu_name = $VLibDefList->{$sqlitedefid}->{'name'};
			}
			my $browsemenu_contributor_allartists = $paramRef->{"pref_browsemenu_contributor_allartists_$n"} // undef;
			my $browsemenu_contributor_albumartists = $paramRef->{"pref_browsemenu_contributor_albumartists_$n"} // undef;
			my $browsemenu_contributor_composers = $paramRef->{"pref_browsemenu_contributor_composers_$n"} // undef;
			my $browsemenu_contributor_conductors = $paramRef->{"pref_browsemenu_contributor_conductors_$n"} // undef;
			my $browsemenu_contributor_trackartists = $paramRef->{"pref_browsemenu_contributor_trackartists_$n"} // undef;
			my $browsemenu_contributor_bands = $paramRef->{"pref_browsemenu_contributor_bands_$n"} // undef;
			my $browsemenu_albums_all = $paramRef->{"pref_browsemenu_albums_all_$n"} // undef;
			my $browsemenu_albums_nocompis = $paramRef->{"pref_browsemenu_albums_nocompis_$n"} // undef;
			my $browsemenu_albums_compisonly = $paramRef->{"pref_browsemenu_albums_compisonly_$n"} // undef;
			my $browsemenu_genres = $paramRef->{"pref_browsemenu_genres_$n"} // undef;
			my $browsemenu_years = $paramRef->{"pref_browsemenu_years_$n"} // undef;
			my $browsemenu_tracks = $paramRef->{"pref_browsemenu_tracks_$n"} // undef;
			my $notUserConfigurable = $VLibDefList->{$sqlitedefid}->{'notuserconfigurable'} // undef;
			my $defaultVLIBdef = $VLibDefList->{$sqlitedefid}->{'defaultvlibdef'} // undef;

			for ($browsemenu_contributor_allartists, $browsemenu_contributor_albumartists, $browsemenu_contributor_composers, $browsemenu_contributor_conductors, $browsemenu_contributor_trackartists, $browsemenu_contributor_bands, $browsemenu_albums_all, $browsemenu_albums_nocompis, $browsemenu_albums_compisonly, $browsemenu_genres, $browsemenu_years, $browsemenu_tracks) {
			$num_menus_enabled++ if defined;
			}
			$log->debug('number of browse menus enabled for \''.$browsemenu_name.'\' = '.$num_menus_enabled);
			if (!$sqlitedefDone{$sqlitedefid} && !$browsemenu_nameDone{$browsemenu_name}) {
				$virtuallibrariesmatrix{$virtuallibrariesconfigID} = {
					'enabled' => $enabled,
					'sqlitedefid' => $sqlitedefid,
					'browsemenu_name' => $browsemenu_name,
					'numberofenabledbrowsemenus' => $num_menus_enabled,
					'browsemenu_contributor_allartists' => $browsemenu_contributor_allartists,
					'browsemenu_contributor_albumartists' => $browsemenu_contributor_albumartists,
					'browsemenu_contributor_composers' => $browsemenu_contributor_composers,
					'browsemenu_contributor_conductors' => $browsemenu_contributor_conductors,
					'browsemenu_contributor_trackartists' => $browsemenu_contributor_trackartists,
					'browsemenu_contributor_bands' => $browsemenu_contributor_bands,
					'browsemenu_albums_all' => $browsemenu_albums_all,
					'browsemenu_albums_nocompis' => $browsemenu_albums_nocompis,
					'browsemenu_albums_compisonly' => $browsemenu_albums_compisonly,
					'browsemenu_genres' => $browsemenu_genres,
					'browsemenu_years' => $browsemenu_years,
					'browsemenu_tracks' => $browsemenu_tracks,
					'notuserconfigurable' => $notUserConfigurable,
					'defaultvlibdef' => $defaultVLIBdef
			};

				$sqlitedefDone{$sqlitedefid} = 1;
				$browsemenu_nameDone{$browsemenu_name} = 1;
			}
		}
		$prefs->set('virtuallibrariesmatrix', \%virtuallibrariesmatrix);
		$paramRef->{virtuallibrariesmatrix} = \%virtuallibrariesmatrix;
		$log->debug('SAVED VALUES = '.Dumper(\%virtuallibrariesmatrix));

		$result = $class->SUPER::handler($client, $paramRef);
	}

	# push to settings page

	my $virtuallibrariesmatrix = $prefs->get('virtuallibrariesmatrix');
	my $virtuallibrariesconfiglist;
	foreach my $virtuallibrariesconfig (sort keys %{$virtuallibrariesmatrix}) {
		$log->debug('virtuallibrariesconfig = '.$virtuallibrariesconfig);
		my $sqlitedefid = $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'sqlitedefid'};
		$log->debug('sqlitedefid = '.$sqlitedefid);
		push (@{$virtuallibrariesconfiglist}, {
			'enabled' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'enabled'},
			'sqlitedefid' => $sqlitedefid,
			'browsemenu_name' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_name'},
			'numberofenabledbrowsemenus' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'numberofenabledbrowsemenus'},
			'browsemenu_contributor_allartists' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_allartists'},
			'browsemenu_contributor_albumartists' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_albumartists'},
			'browsemenu_contributor_composers' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_composers'},
			'browsemenu_contributor_conductors' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_conductors'},
			'browsemenu_contributor_trackartists' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_trackartists'},
			'browsemenu_contributor_bands' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_contributor_bands'},
			'browsemenu_albums_all' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_albums_all'},
			'browsemenu_albums_nocompis' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_albums_nocompis'},
			'browsemenu_albums_compisonly' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_albums_compisonly'},
			'browsemenu_genres' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_genres'},
			'browsemenu_years' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_years'},
			'browsemenu_tracks' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'browsemenu_tracks'},
			'notuserconfigurable' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'notuserconfigurable'},
			'defaultvlibdef' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'defaultvlibdef'}
		});
	}

	my (@virtuallibrariesconfiglistsortedDefaultVLIBs, @virtuallibrariesconfiglistsorted, @virtuallibrariesconfiglistsortedDefaultVLIBsDisabled, @virtuallibrariesconfiglistsortedDisabled);
	foreach my $thisconfig (@{$virtuallibrariesconfiglist}) {
		if (defined $thisconfig->{'enabled'}) {
			if ($thisconfig->{'defaultvlibdef'}) {
				push @virtuallibrariesconfiglistsortedDefaultVLIBs, $thisconfig;
			} else {
				push @virtuallibrariesconfiglistsorted, $thisconfig;
			}
		} else {
			if ($thisconfig->{'defaultvlibdef'}) {
				push @virtuallibrariesconfiglistsortedDefaultVLIBsDisabled, $thisconfig;
			} else {
				push @virtuallibrariesconfiglistsortedDisabled, $thisconfig;
			}
		}
	}
	@virtuallibrariesconfiglistsortedDefaultVLIBs = sort {lc($a->{browsemenu_name}) cmp lc($b->{browsemenu_name})} @virtuallibrariesconfiglistsortedDefaultVLIBs if scalar @virtuallibrariesconfiglistsortedDefaultVLIBs > 0;

	@virtuallibrariesconfiglistsorted = sort {lc($a->{browsemenu_name}) cmp lc($b->{browsemenu_name})} @virtuallibrariesconfiglistsorted if scalar @virtuallibrariesconfiglistsorted > 0;

	@virtuallibrariesconfiglistsortedDefaultVLIBsDisabled = sort {lc($a->{browsemenu_name}) cmp lc($b->{browsemenu_name})} @virtuallibrariesconfiglistsortedDefaultVLIBsDisabled if scalar @virtuallibrariesconfiglistsortedDefaultVLIBsDisabled > 0;

	@virtuallibrariesconfiglistsortedDisabled = sort {lc($a->{browsemenu_name}) cmp lc($b->{browsemenu_name})} @virtuallibrariesconfiglistsortedDisabled if scalar @virtuallibrariesconfiglistsortedDisabled > 0;

	my @pagevirtuallibrariesconfiglistsorted = (@virtuallibrariesconfiglistsortedDefaultVLIBs, @virtuallibrariesconfiglistsorted, @virtuallibrariesconfiglistsortedDefaultVLIBsDisabled, @virtuallibrariesconfiglistsortedDisabled);

	# add empty row
	if ((scalar @pagevirtuallibrariesconfiglistsorted + 1) < $maxItemNum) {
		push(@pagevirtuallibrariesconfiglistsorted, {
			'enabled' => undef,
			'sqlitedefid' => '',
			'browsemenu_name' => '',
			'numberofenabledbrowsemenus' => 0,
			'browsemenu_contributor_allartists' => undef,
			'browsemenu_contributor_albumartists' => undef,
			'browsemenu_contributor_composers' => undef,
			'browsemenu_contributor_conductors' => undef,
			'browsemenu_contributor_trackartists' => undef,
			'browsemenu_contributor_bands' => undef,
			'browsemenu_albums_all' => undef,
			'browsemenu_albums_nocompis' => undef,
			'browsemenu_albums_compisonly' => undef,
			'browsemenu_genres' => undef,
			'browsemenu_years' => undef,
			'browsemenu_tracks' => undef,
			'notuserconfigurable' => undef,
			'defaultvlibdef' => undef
		});
	}

	$paramRef->{virtuallibrariesmatrix} = \@pagevirtuallibrariesconfiglistsorted;
	$paramRef->{itemcount} = scalar @pagevirtuallibrariesconfiglistsorted;
	$log->debug('list pushed to page = '.Dumper($paramRef->{virtuallibrariesmatrix}));

	$result = $class->SUPER::handler($client, $paramRef);

	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	my $VLibDefList = Plugins::SQLiteVirtualLibraries::Plugin::getVLibDefList();
	$log->debug('VLibDefList = '.Dumper($VLibDefList));
	my $vliblistcount = keys %{$VLibDefList};
	$log->debug('vliblistcount = '.Dumper($vliblistcount));
	my @sortedVLarray;
	if ($vliblistcount > 0) {
		my (@pageDefaultVLArray, @pageCustomVLarray);
		for my $thisVLIB (keys %{$VLibDefList}) {
			my $thisVLIBname = $VLibDefList->{$thisVLIB}->{'name'};
			my $defaultVLib = $VLibDefList->{$thisVLIB}->{'defaultvlibdef'};
			my $VLIBsortname = $defaultVLib ? '000000000_'.$thisVLIBname : $thisVLIBname;
			my $thisVlibID = $VLibDefList->{$thisVLIB}->{'id'};
			if ($defaultVLib) {
				push @pageDefaultVLArray, {'name' => $thisVLIBname, 'sortname' => $VLIBsortname, 'id' => $thisVlibID, 'defaultvlib' => $defaultVLib};
			} else {
				push @pageCustomVLarray, {'name' => $thisVLIBname, 'sortname' => $VLIBsortname, 'id' => $thisVlibID, 'defaultvlib' => $defaultVLib};
			}
		}
		if (scalar @pageCustomVLarray == 0) {
			push @pageCustomVLarray, {'name' => string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_NOVLIBDEFS_SHORT'), 'sortname' => 'none', 'id' => 'none', 'defaultvlib' => undef};
		}
		@sortedVLarray = (@pageDefaultVLArray, @pageCustomVLarray);
		@sortedVLarray = sort {lc($a->{'sortname'}) cmp lc($b->{'sortname'})} @sortedVLarray;
		$log->debug('sorted playlists = '.Dumper(\@sortedVLarray));
	} else {
		push @sortedVLarray, {'name' => string("PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_NOVLIBDEFS"), 'id' => 'none'};
	}
	$paramRef->{'vliblistcount'} = $vliblistcount;
	$paramRef->{'allvirtuallibraries'} = \@sortedVLarray;
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

1;
