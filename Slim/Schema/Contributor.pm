package Slim::Schema::Contributor;

# $Id$

use strict;
use base 'Slim::Schema::DBI';

use Scalar::Util qw(blessed);

use Slim::Schema::ResultSet::Contributor;

use Slim::Utils::Log;
use Slim::Utils::Misc;

our %contributorToRoleMap = (
	'ARTIST'      => 1,
	'COMPOSER'    => 2,
	'CONDUCTOR'   => 3,
	'BAND'        => 4,
	'ALBUMARTIST' => 5,
	'TRACKARTIST' => 6,
);

our %roleToContributorMap = reverse %contributorToRoleMap;

{
	my $class = __PACKAGE__;

	$class->table('contributors');

	$class->add_columns(qw(
		id
		name
		namesort
		musicmagic_mixable
		namesearch
		musicbrainz_id
	));

	$class->set_primary_key('id');
	$class->add_unique_constraint('namesearch' => [qw/namesearch/]);

	$class->has_many('contributorTracks' => 'Slim::Schema::ContributorTrack');
	$class->has_many('contributorAlbums' => 'Slim::Schema::ContributorAlbum');
	
	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();

	$class->many_to_many('tracks', 'contributorTracks' => 'contributor', undef, {
		'distinct' => 1,
		'order_by' => ['disc', 'tracknum', "titlesort $collate"], # XXX won't change if language changes
	});

	$class->many_to_many('albums', 'contributorAlbums' => 'album', undef, { 'distinct' => 1 });

	if ($] > 5.007) {
		$class->utf8_columns(qw/name namesort namesearch/);
	}

	$class->resultset_class('Slim::Schema::ResultSet::Contributor');
}

sub contributorRoles {
	my $class = shift;

	return sort keys %contributorToRoleMap;
}

sub totalContributorRoles {
	my $class = shift;

	return scalar keys %contributorToRoleMap;
}

sub typeToRole {
	return $contributorToRoleMap{$_[1]} || $_[1];
}

sub roleToType {
	return $roleToContributorMap{$_[1]};
}

sub displayAsHTML {
	my ($self, $form, $descend, $sort) = @_;

	my $vaString = Slim::Music::Info::variousArtistString();

	$form->{'text'} = $self->name;
	
	if ($self->name eq $vaString) {
		$form->{'attributes'} .= "&album.compilation=1";
	}

	my $Imports = Slim::Music::Import->importers;

	for my $mixer (keys %{$Imports}) {

		if (defined $Imports->{$mixer}->{'mixerlink'}) {
			&{$Imports->{$mixer}->{'mixerlink'}}($self, $form, $descend);
		}
	}
}

# For saving favorites.
sub url {
	my $self = shift;

	return sprintf('db:contributor.name=%s', URI::Escape::uri_escape_utf8($self->name));
}

sub add {
	my $class = shift;
	my $args  = shift;

	# Pass args by name
	my $artist     = $args->{'artist'} || return;
	my $brainzID   = $args->{'brainzID'};

	my @contributors = ();

	# Bug 1955 - Previously 'last one in' would win for a
	# contributorTrack - ie: contributor & role combo, if a track
	# had an ARTIST & COMPOSER that were the same value.
	#
	# If we come across that case, force the creation of a second
	# contributorTrack entry.
	#
	# Split both the regular and the normalized tags
	my @artistList   = Slim::Music::Info::splitTag($artist);
	my @sortedList   = $args->{'sortBy'} ? Slim::Music::Info::splitTag($args->{'sortBy'}) : @artistList;
	
	# Using native DBI here to improve performance during scanning
	my $dbh = Slim::Schema->dbh;

	for (my $i = 0; $i < scalar @artistList; $i++) {

		# Bug 10324, we now match only the exact name
		my $name   = $artistList[$i];
		my $search = Slim::Utils::Text::ignoreCaseArticles($name);
		my $sort   = Slim::Utils::Text::ignoreCaseArticles(($sortedList[$i] || $name));
		
		my $sth = $dbh->prepare_cached( 'SELECT id FROM contributors WHERE name = ?' );
		$sth->execute($search);
		my ($id) = $sth->fetchrow_array;
		$sth->finish;
		
		if ( !$id ) {
			$sth = $dbh->prepare_cached( qq{
				INSERT INTO contributors
				(name, namesort, namesearch, musicbrainz_id)
				VALUES
				(?, ?, ?, ?)
			} );
			$sth->execute( $name, $sort, $search, $brainzID );
			$id = $dbh->last_insert_id(undef, undef, undef, undef);
		}
		else {
			# Bug 3069: update the namesort only if it's different than namesearch
			if ( $search ne $sort ) {
				$sth = $dbh->prepare_cached('UPDATE contributors SET namesort = ? WHERE id = ?');
				$sth->execute( $sort, $id );
			}
		}
		
		push @contributors, $id;
	}

	return wantarray ? @contributors : $contributors[0];
}

# Rescan list of contributors, this simply means to make sure at least 1 track
# from this contributor still exists in the database.  If not, delete the contributor.
sub rescan {
	my ( $class, @ids ) = @_;
	
	my $log = logger('scan.scanner');
	
	my $dbh = Slim::Schema->dbh;
	
	for my $id ( @ids ) {
		my $sth = $dbh->prepare_cached( qq{
			SELECT COUNT(*) FROM contributor_track WHERE contributor = ?
		} );
		$sth->execute($id);
		my ($count) = $sth->fetchrow_array;
		$sth->finish;
	
		if ( !$count ) {
			main::DEBUGLOG && $log->is_debug && $log->debug("Removing unused contributor: $id");

			# This will cascade within the database to contributor_album and contributor_track
			$dbh->do( "DELETE FROM contributors WHERE id = ?", undef, $id );
		}
	}
}

1;

__END__
