package Slim::Plugin::Podcast::ProtocolHandler;

# Logitech Media Server Copyright 2005-2020 Logitech.

# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use base qw(Slim::Player::Protocols::HTTPS);

use strict;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;

my $log   = logger('plugin.podcast');
my $prefs = preferences('plugin.podcast');
my $cache = Slim::Utils::Cache->new;
my $cachePrefix;

Slim::Player::ProtocolHandlers->registerHandler('podcast', __PACKAGE__);

# remove podcast:// protocol to scan real url
sub scanUrl {
	my ( $class, $url, $args ) = @_;
	my $track = $args->{song}->track;
	my ($scanUrl, $from) = Slim::Plugin::Podcast::Plugin::unwrapUrl($url);	
	
	main::INFOLOG && $log->info("Scanning podcast $url for title ", $track->title);

	# as for redirect, need to port to new url the cover/icon set in XMLBrowser
	if ( my $icon = $cache->get($cachePrefix . $url) ) {
		$cache->set($cachePrefix . $scanUrl, $icon, '30 days');
	}
	
	$args->{song}->seekdata( { timeOffset => $from } ) if $from;
	$class->SUPER::scanUrl($scanUrl, $args);
}

# we want the image to be cached for us (we will port it only when needed)
sub cacheImage {
	my ($class, $url, $image, $prefix) = @_;
	return $cachePrefix = $prefix;
}

sub new {
	my ($class, $args) = @_;
	my $song = $args->{song};	
	my $startTime = $song->seekdata->{timeOffset} if $song->seekdata;
	
	main::INFOLOG && $log->info( "Streaming podcast $args->{url} from $startTime" );
	
	# erase last position from cache
	my ($url) = Slim::Plugin::Podcast::Plugin::unwrapUrl($song->originUrl);
	$cache->remove('podcast-' . $url) if $url;
	
	if ($startTime) {
		my $seekdata = $song->getSeekData($startTime);
		$song->seekdata($seekdata);
	}
	
	return $class->SUPER::new( $args );
}

sub onStop {
    my ($self, $song) = @_;
	my $elapsed = $song->master->controller->playingSongElapsed;
	my ($url) = Slim::Plugin::Podcast::Plugin::unwrapUrl($song->originUrl);

	if ($elapsed > 15 && (!$song->duration || $elapsed < $song->duration - 15)) {
		$cache->set("podcast-$url", int ($elapsed), '30days');
		main::INFOLOG && $log->info("Last position for $url is $elapsed");
	} else {
		$cache->remove("podcast-$url");
	}		
}

sub onStream {
	my ($self, $client, $song) = @_;
	
	Slim::Plugin::Podcast::Plugin->updateRecentlyPlayed( $client, $song );
}


1;
