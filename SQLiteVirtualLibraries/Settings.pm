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
		my %notUserConfigurableHomeMenus = map {$_ => 1} ('compisrandom', 'compisbygenre');

		for (my $n = 0; $n <= $maxItemNum; $n++) {
			my $num_menus_enabled = 0;
			my $virtuallibrariesconfigID = $paramRef->{"pref_idNum_$n"};
			$log->debug('virtuallibrariesconfigID = '.Dumper($virtuallibrariesconfigID));
			next if (!defined $virtuallibrariesconfigID);
			my $enabled = $paramRef->{"pref_enabled_$n"} // undef;
			my $sqlitedefid = $paramRef->{"pref_sqlitedefid_$n"} // undef;
			$log->debug('sqlitedefid = '.Dumper($sqlitedefid));
			next if (!$sqlitedefid || ($sqlitedefid eq '') || ($sqlitedefid eq 'none'));
			my $VLsource = $VLibDefList->{$sqlitedefid}->{'vlibsource'} // 3;
			my $browsemenu_name = trim_leadtail($paramRef->{"pref_browsemenu_name_$n"} // '');
			if (($browsemenu_name eq '') || ($browsemenu_name =~ m|[\^{}$@<>"#%?*:/\|\\]|)) {
				if ($VLsource == 3) {
					$browsemenu_name = Slim::Music::VirtualLibraries->getNameForId($sqlitedefid);
					$log->info('sqlitedefid = '.$sqlitedefid.' -- browsemenu_name = '.$browsemenu_name);
				} else {
					$browsemenu_name = $VLibDefList->{$sqlitedefid}->{'name'};
				}
			}
			my $homeMenu = $paramRef->{"pref_homemenu_$n"} // undef;
			$homeMenu = 1 if $notUserConfigurableHomeMenus{$sqlitedefid};
			my $menuWeight = $paramRef->{"pref_menuweight_$n"} // undef;
			$menuWeight = undef if (defined $menuWeight && (!$homeMenu || $menuWeight !~ /^-?\d+\z/ || $menuWeight <= 0));
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
					'homemenu' => $homeMenu,
					'menuweight' => $menuWeight,
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
					'vlibsource' => $VLsource
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
			'homemenu' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'homemenu'},
			'menuweight' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'menuweight'},
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
			'vlibsource' => $virtuallibrariesmatrix->{$virtuallibrariesconfig}->{'vlibsource'}
		});
	}

	my (@configlistSortedDefaultVLs, @configlistSortedDefaultVLsDisabled, @configlistSortedCustomVLs, , @configlistSortedCustomVLsDisabled , @configlistSortedExternalVLs, @configlistSortedExternalVLsDisabled);
	foreach my $thisconfig (@{$virtuallibrariesconfiglist}) {
		if ($thisconfig->{'vlibsource'} == 1) {
			defined $thisconfig->{'enabled'} ? push @configlistSortedDefaultVLs, $thisconfig : push @configlistSortedDefaultVLsDisabled, $thisconfig;
		} elsif ($thisconfig->{'vlibsource'} == 2) {
			defined $thisconfig->{'enabled'} ? push @configlistSortedCustomVLs, $thisconfig : push @configlistSortedCustomVLsDisabled, $thisconfig;
		} elsif ($thisconfig->{'vlibsource'} == 3) {
			defined $thisconfig->{'enabled'} ? push @configlistSortedExternalVLs, $thisconfig : push @configlistSortedExternalVLsDisabled, $thisconfig;
		}
	}
	@configlistSortedDefaultVLs = sort {lc($a->{browsemenu_name}) cmp lc($b->{browsemenu_name})} @configlistSortedDefaultVLs if scalar @configlistSortedDefaultVLs > 0;

	@configlistSortedDefaultVLsDisabled = sort {lc($a->{browsemenu_name}) cmp lc($b->{browsemenu_name})} @configlistSortedDefaultVLsDisabled if scalar @configlistSortedDefaultVLsDisabled > 0;

	@configlistSortedCustomVLs = sort {lc($a->{browsemenu_name}) cmp lc($b->{browsemenu_name})} @configlistSortedCustomVLs if scalar @configlistSortedCustomVLs > 0;

	@configlistSortedCustomVLsDisabled = sort {lc($a->{browsemenu_name}) cmp lc($b->{browsemenu_name})} @configlistSortedCustomVLsDisabled if scalar @configlistSortedCustomVLsDisabled > 0;

	@configlistSortedExternalVLs = sort {lc($a->{browsemenu_name}) cmp lc($b->{browsemenu_name})} @configlistSortedExternalVLs if scalar @configlistSortedExternalVLs > 0;

	@configlistSortedExternalVLsDisabled = sort {lc($a->{browsemenu_name}) cmp lc($b->{browsemenu_name})} @configlistSortedExternalVLsDisabled if scalar @configlistSortedExternalVLsDisabled > 0;

	my @pageVLsConfiglistSorted = (@configlistSortedDefaultVLs, @configlistSortedCustomVLs, @configlistSortedDefaultVLsDisabled, @configlistSortedCustomVLsDisabled, @configlistSortedExternalVLs, @configlistSortedExternalVLsDisabled);

	# add empty row
	if ((scalar @pageVLsConfiglistSorted + 1) < $maxItemNum) {
		push(@pageVLsConfiglistSorted, {
			'enabled' => undef,
			'sqlitedefid' => '',
			'browsemenu_name' => '',
			'numberofenabledbrowsemenus' => 0,
			'homemenu' => undef,
			'menuweight' => undef,
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
			'vlibsource' => undef
		});
	}

	$paramRef->{virtuallibrariesmatrix} = \@pageVLsConfiglistSorted;
	$paramRef->{itemcount} = scalar @pageVLsConfiglistSorted;
	$log->debug('list pushed to page = '.Dumper($paramRef->{virtuallibrariesmatrix}));

	$result = $class->SUPER::handler($client, $paramRef);

	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	my $extVLibraries = Slim::Music::VirtualLibraries->getLibraries();
	$log->debug('extVLibraries = '.Dumper($extVLibraries));
	my @pageExtVLarray;
	for my $thisExtVL (keys %{$extVLibraries}) {
		my $thisExtVLname = $extVLibraries->{$thisExtVL}->{'name'};
		my $thisExtVLid = $extVLibraries->{$thisExtVL}->{'id'};
		$log->debug('thisExtVLname = '.$thisExtVLname.' -- thisExtVLid = '.$thisExtVLid);
		if (starts_with($thisExtVLid, 'PLUGIN_SQLVL_VLID_') != 0) {
			push @pageExtVLarray, {'name' => $thisExtVLname, 'sortname' => $thisExtVLname, 'id' => $thisExtVLid, 'vlibsource' => 3};
		}
	}
	if (scalar @pageExtVLarray == 0) {
		push @pageExtVLarray, {'name' => string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_NOVLIBDEFS_SHORT'), 'sortname' => 'none', 'id' => 'none', 'vlibsource' => 3};
	}

	my $VLibDefList = Plugins::SQLiteVirtualLibraries::Plugin::getVLibDefList();
	$log->debug('VLibDefList = '.Dumper($VLibDefList));
	my $vliblistcount = keys %{$VLibDefList};
	$log->debug('vliblistcount = '.Dumper($vliblistcount));
	my $defaultVLcount = 0;
	my $customVLcount = 0;
	my @pageVLarray;
	for my $thisVLIB (keys %{$VLibDefList}) {
		my $thisVLIBname = $VLibDefList->{$thisVLIB}->{'name'};
		my $VLsource = $VLibDefList->{$thisVLIB}->{'vlibsource'};
		my $VLIBsortname = $VLsource == 1 ? '000000000_'.$thisVLIBname : $thisVLIBname;
		$VLsource == 1 ? $defaultVLcount++ : $customVLcount++;
		my $thisVlibID = $VLibDefList->{$thisVLIB}->{'id'};
		push @pageVLarray, {'name' => $thisVLIBname, 'sortname' => $VLIBsortname, 'id' => $thisVlibID, 'vlibsource' => $VLsource};
	}
	if ($defaultVLcount == 0) {
		push @pageExtVLarray, {'name' => string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_NOVLIBDEFS_SHORT'), 'sortname' => 'none', 'id' => 'none', 'vlibsource' => 1};
	}
	if ($customVLcount == 0) {
		push @pageExtVLarray, {'name' => string('PLUGIN_SQLITEVIRTUALLIBRARIES_SETTINGS_NOVLIBDEFS_SHORT'), 'sortname' => 'none', 'id' => 'none', 'vlibsource' => 2};
	}
	my @sortedVLarray = (@pageVLarray, @pageExtVLarray);
	@sortedVLarray = sort {lc($a->{'sortname'}) cmp lc($b->{'sortname'})} @sortedVLarray;
	$log->debug('sorted playlists = '.Dumper(\@sortedVLarray));
	$paramRef->{'allvirtuallibraries'} = \@sortedVLarray;
}

sub starts_with {
	# complete_string, start_string, position
	return rindex($_[0], $_[1], 0);
	# returns 0 for yes, -1 for no
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
