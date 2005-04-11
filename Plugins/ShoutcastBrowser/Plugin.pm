# ShoutcastBrowser.pm Copyright (C) 2003 Peter Heslin
# version 3.0, 5 Apr, 2004
#$Id: ShoutcastBrowser.pm 2620 2005-03-21 08:40:35Z mherger $
#
# A Slim plugin for browsing the Shoutcast directory of mp3
# streams.  Inspired by streamtuner.
#
# With contributions from Okko, Kevin Walsh and Rob Funk.
#
# This code is derived from code with the following copyright message:
#
# Slim Server Copyright (C) 2001 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

# To Do:
#
# * Get rid of hard-coded @genre_keywords, and generate it
#  instead from a word frequency list -- which will mean a list of
#  excluded, rather than included, words.
#
# * Add a web interface

package Plugins::ShoutcastBrowser::Plugin;

use strict;
use IO::Socket qw(:crlf);
use File::Spec::Functions qw(catdir catfile);
use Slim::Control::Command;
use Slim::Utils::Strings qw (string);
use HTML::Entities qw(decode_entities);
use XML::Simple;

################### Configuration Section ########################

### These first few preferences can only be set by editing this file
my (%genre_aka, @genre_keywords, @legit_genres);

# If you choose to munge the genres, here is the list of keywords that
# define various genres.  If any of these words or phrases is found in
# the genre of a stream, then the stream is allocated to the genre
# indicated by those word(s) or phrase(s).  In phrases, indicate a
# space by means of an underscore.  The order is significant if
# Slim::Utils::Prefs::getArray('plugin_shoutcastbrowser_genre_criterion') contains "keywords".

@genre_keywords = qw{
	rock pop trance dance techno various house alternative 80s metal
	college jazz talk world rap ambient oldies electronic blues country
	punk reggae 70s classical live latin indie downtempo gospel
	industrial scanner unknown 90s hardcore folk comedy urban funk
	progressive ska 60s breakbeat smooth anime news soul lounge goa
	soundtrack bluegrass salsa dub swing chillout contemporary garage
	chinese russian greek jpop kpop jungle zabavna african punjabi
	sports asian disco korean hindi japanese psychedelic indian
	dancehall adult instrumental vietnam narodna eurodance celtic 50s
	merengue hardstyle persian tamil gothic npr spanish remix community
	cpop arabic jrock space international freeform acid bhangra
	kabar opera german iranian dominicana deephouse africa rave
	hardhouse irish turkish malay stoner ethnic rocksteady remixes
	croatian hardtrance polka glam americana mexican pakistani
	iraqi hungarian bosna bossa italian didjeridu acadian coptic brazil
	greece kurd rockabilly top_40 hard_rock hard_core video_game
	big_band classic_rock easy_listening pink_floyd new_age zouk
	drum_&_bass r_&_b
};

# Here are keywords defined in terms of other, variant keywords.  The
# form on the right is the canonical form, and on the left is the
# variant or list of variants which should be transformed into that
# canonical form.

%genre_aka = (
	'50' => '50s', 
	'60' => '60s',
	'70' => '70s',  
	'80' => '80s',  
	'90' => '90s', 
	'africa' => 'african',
	'animation' => 'anime', 
	'any|every|mixed|eclectic|mix|variety|varied|random|misc' => 'various', 
	'breakbeats' => 'breakbeat', 
	'britpop' => 'british',
	'christian|praise|worship|prayer|inspirational|bible|religious' => 'spiritual',
	'dnb|d&b|d & b|drum and bass|drum|bass' => 'drum & bass', 
	'electro|electronica' => 'electronic',
	'film|movie' => 'soundtrack',
	'freestyle' => 'freeform', 
	'greece' => 'greek', 
	'goth' => 'gothic',
	'hiphop|hip hop' => 'rap', 
	'holland|netherland|nederla' => 'dutch', 
	'humor|humour' => 'comedy', 
	'hungar' => 'hungarian', 
	'local' => 'community', 
	'lowfi|lofi' => 'low fi',
	'newage' => 'new age',
	'oldie' => 'oldies', 
	'oldskool|old skool|oldschool' => 'old school', 
	'psych' => 'psychedelic',
	'punjab' => 'punjabi',
	'ragga|dancehall|dance hall' => 'reggae', 
	'rnb|r n b|r&b' => 'r & b',  
	'spoken|politics' => 'talk', 
	'symphonic' => 'classical',
	'top40|chart|top hits' => 'top 40', 
	'tranc' => 'trance', 
	'turk|t.rkce' => 'turkish',
	'videogame gaming' => 'video_game', 
	'vivo' => 'live'
);

## These are useful, descriptive genres, which should not be removed
## from the list, even when they only have one stream and we are
## lumping singletons together.  So we eliminate the more obscure and
## regional genres from this list.

@legit_genres = qw(
	rock pop trance dance techno various house alternative 80s metal
	college jazz talk world rap ambient oldies blues country punk reggae
	70s classical live latin indie downtempo gospel industrial scanner 90s
	folk comedy urban funk progressive ska 60s news soul lounge soundtrack
	bluegrass salsa swing sports disco 50s merengue opera top_40 hard_rock
	hard_core video_game big_band classic_rock easy_listening new_age
);

################### End Configuration Section ####################

# rather constants than variables (never changed in the code)
use constant SORT_BITRATE_UP => 0;
use constant RECENT_DIRNAME => 'ShoutcastBrowser_Recently_Played';
use constant POSITION_OF_RECENT => 0;

## Order for info sub-mode
my (@info_order, @info_index);

my %custom_genres;

# keep track of client status
# TODO mh: put these back to "my" ("our" only for debugging)!
my (%status, %stream_data, %genres_data);


# time of last list refresh
my $last_time = 0;

checkDefaults();

@genre_keywords = map { s/_/ /g; $_; } @genre_keywords;
@legit_genres = map { s/_/ /g; $_; } @legit_genres;

my %keyword_index;
{
	my $i = 1;
	for (@genre_keywords) {
		$keyword_index{$_} = $i;
		$i++;
	}
}

sub getDisplayName {
	return 'PLUGIN_SHOUTCASTBROWSER_MODULE_NAME';
}

sub getAllName {
	my $client = shift;
	if (defined $client) {
		return $client->string('PLUGIN_SHOUTCASTBROWSER_ALL_STREAMS');
	}
	else {
		return string('PLUGIN_SHOUTCASTBROWSER_ALL_STREAMS');
	}
}

sub getRecentName {
	my $client = shift;
	if (defined $client) {
		return $client->string('PLUGIN_SHOUTCASTBROWSER_RECENT');
	}
	else {
		return string('PLUGIN_SHOUTCASTBROWSER_RECENT');
	}
}

sub getMostPopularName {
	my $client = shift;
	if (defined $client) {
		return $client->string('PLUGIN_SHOUTCASTBROWSER_MOST_POPULAR');
	}
	else {
		return string('PLUGIN_SHOUTCASTBROWSER_MOST_POPULAR');
	}
}

sub getMiscName {
	my $client = shift;
	if (defined $client) {
		return $client->string('PLUGIN_SHOUTCASTBROWSER_MISC');
	}
	else {
		return string('PLUGIN_SHOUTCASTBROWSER_MISC');
	}
}

sub setup_custom_genres {
	my $i = 1;
	
	open FH, Slim::Utils::Prefs::get('plugin_shoutcastbrowser_custom_genres') or return;
	{
		while(my $entry = <FH>) {
			
			chomp $entry;
			
			next if $entry =~ m/^\s*$/;
			my ($genre, @patterns) = split ' ', $entry;
			
			$genre =~ s/_/ /g;
			
			for (@patterns)
			{
				$_ = "\L$_";
				$_ =~ s/_/ /g;
			}
			
			$custom_genres{$genre} = join '|', @patterns;
			$genre = lc($genre);
			$keyword_index{$genre} = $i;
			$i++;
		}
		
	close FH;
	}
}

my $popular_sort = sub {
	my $r = 0;
	my ($aa, $bb) = (0, 0);
	
	$aa += $stream_data{getAllName()}{$a}{$_}[1] 
		foreach keys %{ $stream_data{getAllName()}{$a} };
		
	$bb += $stream_data{getAllName()}{$b}{$_}[1]
		foreach keys %{ $stream_data{getAllName()}{$b} };

	$r = $bb <=> $aa;
	return $r if $r;

	return lc($a) cmp lc($b);
};


##### Main mode for genres #####

sub setMode {
	my $client = shift;
	
	$client->lines(\&lines);
	$status{$client}{status} = 0;
	$status{$client}{number} = undef;
	$client->update();
	
	@info_order = ($client->string('BITRATE'), $client->string('PLUGIN_SHOUTCASTBROWSER_STREAM_NAME'), $client->string('SETUP_PLUGIN_SHOUTCASTBROWSER_NUMBEROFLISTENERS'), $client->string('GENRE'), $client->string('PLUGIN_SHOUTCASTBROWSER_WAS_PLAYING'), $client->string('URL') );
	@info_index = (                    2,                                         -1,                                                          1,                                               4,                                         3,                                   0);

	if (not loadStreamList()) {
		$status{$client}{number} = undef;
		$client->showBriefly($client->string('PLUGIN_SHOUTCASTBROWSER_MODULE_NAME'), $client->string('PLUGIN_SHOUTCASTBROWSER_NETWORK_ERROR'));
		Slim::Buttons::Common::popModeRight($client);
	}
	
	$status{$client}{status} = 1;
	$client->update();
}

sub loadStreamList {
	my $client = shift;
	
	# only reload every hour
	return 1 if (%stream_data and (time() <= $last_time + 3600));

	eval { require Compress::Zlib };
	my $have_zlib = 1 unless $@;

	%stream_data = ();
	if (defined $client) {
		$status{$client}{genre} = 0;
		$status{$client}{stream} = 0;
		$status{$client}{streams} = ();
		$status{$client}{bitrate} = 0;
	}

	my $u = unpack 'u', q{M:'1T<#HO+W-H;W5T8V%S="YC;VTO<V)I;B]X;6QL:7-T97(N<&AT;6P_<V5R+=FEC93U3;&E-4#,`};
	$u .= '&no_compress=1' unless $have_zlib;
	$u .= '&limit=' . Slim::Utils::Prefs::get('plugin_shoutcastbrowser_how_many_streams') if Slim::Utils::Prefs::get('plugin_shoutcastbrowser_how_many_streams');

	my $http = Slim::Player::Source::openRemoteStream($u) || do {
		if (defined $client) {
			$status{$client}{status} = -1;
			$client->update();
		}
		return 0;
	};

	my $xml  = $http->content();
	$http->close();
	undef $http;
	
	$last_time = time();

	my $custom_genres = Slim::Utils::Prefs::get('plugin_shoutcastbrowser_custom_genres');
	&setup_custom_genres() if $custom_genres;
	
	my $munge_genres = Slim::Utils::Prefs::get('plugin_shoutcastbrowser_munge_genre');
	
	unless ($xml) {
		if (defined $client) {
			$status{$client}{status} = -1;
			$client->update();
		}
		return 0;
	}
	
	if ($have_zlib) {
		$xml = Compress::Zlib::uncompress($xml);
	}

	my @criterions = Slim::Utils::Prefs::getArray('plugin_shoutcastbrowser_genre_criterion');
	my $min_bitrate = Slim::Utils::Prefs::get('plugin_shoutcastbrowser_min_bitrate');
	my $max_bitrate = Slim::Utils::Prefs::get('plugin_shoutcastbrowser_max_bitrate');

	# Using XML::Simple reduces the memory footprint by nearly 2 megs vs the old manual scanning.
	my $data  = XML::Simple::XMLin($xml, SuppressEmpty => '');

	for my $entry (@{$data->{'playlist'}->{'entry'}}) {
		my $bitrate	 = $entry->{'Bitrate'};
		next if ($min_bitrate and $bitrate < $min_bitrate);
		next if ($max_bitrate and $bitrate > $max_bitrate);

		my $url		 = $entry->{'Playstring'};
		my $name		= cleanMe($entry->{'Name'});
		my $genre	   = cleanMe($entry->{'Genre'});
		my $now_playing = cleanMe($entry->{'Nowplaying'});
		my $listeners   = $entry->{'Listeners'};

		my @keywords = ();
		my $original = $genre;

		$genre = "\L$genre";
		$genre =~ s/\s+/ /g;
		$genre =~ s/^ //;
		$genre =~ s/ $//;

		if ($custom_genres) {	
			my $match = 0;
		
			for my $key (keys %custom_genres) {
				my $re = $custom_genres{$key};
				while ($genre =~ m/$re/g) {
					push @keywords, $key;
					$match++;
				}
			}
		
			if ($match == 0) {
				@keywords = (getMiscName());
			}
		
		} elsif ($munge_genres) {
			for (keys %genre_aka) {
				$genre =~ s/\b($_)\b/$genre_aka{$_}/g;
			}

			foreach (grep { $genre =~ /\b$_\b/i } @genre_keywords) {
				push @keywords, "\u$_";
			}

			@keywords = ($genre ? ("\u$genre") : (getMiscName())) unless @keywords;
		
		} else {
			@keywords = ($original);
		}

		foreach my $g (@keywords) {
			$stream_data{$g}{$name}{$bitrate} = [$url, $listeners, $bitrate, $now_playing, $original];
		}
		
		$stream_data{getAllName()}{$name}{$bitrate} = [$url, $listeners, $bitrate, $now_playing, $original];
	}

	undef $xml;

	# remove singletons
	if (($criterions[0] =~ /default/i) and not $custom_genres and Slim::Utils::Prefs::get('plugin_shoutcastbrowser_munge_genre')) {
		foreach my $g (keys %stream_data) {
			my @n = keys %{ $stream_data{$g} };
			
			if (not (grep(/$g/i, @legit_genres) or ($#n > 0))) {
				unless (exists $stream_data{getMiscName()}{$n[0]}) {
					$stream_data{getMiscName()}{$n[0]} = $stream_data{$g}{$n[0]};
				}
				delete $stream_data{$g};
			}
		}

	}
	
	my $genre_sort = sub {
		my $r = 0;
		
		return -1 if $a eq getAllName();
		return 1  if $b eq getAllName();
		return 1  if $a eq getMiscName();
		return -1 if $b eq getMiscName();
		
		for my $criterion (@criterions) {
			
			if ($criterion =~ m/^streams/i)	{
				$r = keys %{ $stream_data{$b} } <=> keys %{ $stream_data{$a} };
			} elsif ($criterion =~ m/^keyword/i) {
				if ($keyword_index{lc($a)}) {
					if ($keyword_index{lc($b)}) {
						$r = $keyword_index{lc($a)} <=> $keyword_index{lc($b)};
					} else {
						$r = -1; 
					}
				} else {
					if ($keyword_index{lc($b)}) { 
						$r = 1; 
					} else {
						$r = 0;
					}
				}
			} elsif ($criterion =~ m/^name/i or $criterion =~ m/^default/i) {
				$r = (lc($a) cmp lc($b));
			}
			
			$r = -1 * $r if $criterion =~ m/reverse$/i;
			return $r if $r;
		}
		return $r;
	};

	$genres_data{genres} = [ sort $genre_sort keys %stream_data ];
	unshift @{$genres_data{genres}}, getMostPopularName();
	unshift @{$genres_data{genres}}, getRecentName();

	$genres_data{top} = [ sort $popular_sort keys %{ $stream_data{getAllName()} } ];
	splice @{$genres_data{top}}, Slim::Utils::Prefs::get('plugin_shoutcastbrowser_max_popular');
	$stream_data{getMostPopularName()} = $stream_data{getAllName()};
	
	1;
}

sub cleanMe {
	my $arg = shift;

	$arg =~ s/%([\dA-F][\dA-F])/chr hex $1/gei;#encoded chars
	$arg = decode_entities($arg);
	$arg =~ s#\b([\w-]) ([\w-]) #$1$2#g;#S P A C E D  W O R D S
	$arg =~ s#\b(ICQ|AIM|MP3Pro)\b##i;# we don't care
	$arg =~ s#\W\W\W\W+# #g;# excessive non-word characters
	$arg =~ s#^\W+##;# leading non-word characters
	$arg =~ s/\s+/ /g;
	return $arg;
}

sub reload_xml {
	my $client = shift;
	
	# only allow reload every 10 minutes
	if (time() < $last_time + 600) {
	
		$status{$client}{status} = -2;
		$client->update();
		sleep 1;
		$status{$client}{status} = 1;
		$client->update();
	
	} else {
	
		$status{$client}{status} = 0;
		$client->update();
		%stream_data = ();
		&setMode($client);
	
	}
}

sub getCurrentGenre {
	my $client = shift;
	return @{$genres_data{genres}}[$status{$client}{genre}];
}

sub getGenreCount {
	return ($#{$genres_data{genres}} + 1);
}

my %functions = (
	
	'up' => sub {
		my $client = shift;
		
		$status{$client}{number} = undef;
		$status{$client}{genre} = Slim::Buttons::Common::scroll(
						$client,
						-1,
						getGenreCount(),
						$status{$client}{genre} || 0,
						);
		
		$client->update();
	},
	
	'down' => sub {
		my $client = shift;
		
		$status{$client}{number} = undef;
		$status{$client}{genre} = Slim::Buttons::Common::scroll(
						$client,
						1,
						getGenreCount(),
						$status{$client}{genre} || 0,
						);
		
		$client->update();
	},
	
	'left' => sub {
		my $client = shift;
		$status{$client}{number} = undef;
		Slim::Buttons::Common::popModeRight($client);
	},
	
	'right' => sub {
		my $client = shift;
		$status{$client}{number} = undef;
		Slim::Buttons::Common::pushModeLeft($client, 'ShoutcastStreams');
	},
	
	'jump_rew' => sub {
		my $client = shift;
		$status{$client}{number} = undef;
		&reload_xml($client);
	},
	
	'numberScroll' => sub {
		my ($client, $button, $digit) = @_;
		
		if ($digit == 0 and (not $status{$client}{number})) {
			$status{$client}{genre} = 0;
		} else {
			$status{$client}{number} .= $digit;
			$status{$client}{genre} = $status{$client}{number} - 1;
		}
		
		$client->update();
	}
);

sub lines {
	my $client = shift;
	my (@lines);

	$status{$client}{genre} ||= 0;

	if ($status{$client}{status} == 0) {
		$lines[0] = $client->string('PLUGIN_SHOUTCASTBROWSER_CONNECTING');
		$lines[1] = '';
	
	} elsif ($status{$client}{status} == -1) {
		$lines[0] = $client->string('PLUGIN_SHOUTCASTBROWSER_NETWORK_ERROR');
		$lines[1] = '';
	
	} elsif ($status{$client}{status} == -2) {
		$lines[0] = $client->string('PLUGIN_SHOUTCASTBROWSER_TOO_SOON');
		$lines[1] = '';
	
	} elsif ($status{$client}{status} == 1) {
		$lines[0] = $client->string('PLUGIN_SHOUTCASTBROWSER_GENRES').
			' (' .
			($status{$client}{genre} + 1) .  ' ' .
				$client->string('OF') .  ' ' .
					getGenreCount() .  ') ' ;
		$lines[1] = getCurrentGenre($client);
		$lines[3] = Slim::Display::Display::symbol('rightarrow');
	}

	return @lines;
}

sub getFunctions { return \%functions; }

sub addMenu { return 'RADIO'; }

sub setupGroup
{
	my %setupGroup = (
		PrefOrder => [
			'plugin_shoutcastbrowser_how_many_streams',
			'plugin_shoutcastbrowser_custom_genres',
			'plugin_shoutcastbrowser_genre_criterion',
			'plugin_shoutcastbrowser_stream_criterion',
			'plugin_shoutcastbrowser_min_bitrate',
			'plugin_shoutcastbrowser_max_bitrate',
			'plugin_shoutcastbrowser_max_recent',
			'plugin_shoutcastbrowser_max_popular',
			'plugin_shoutcastbrowser_munge_genre'
		],
		GroupHead => Slim::Utils::Strings::string('SETUP_GROUP_PLUGIN_SHOUTCASTBROWSER'),
		GroupDesc => Slim::Utils::Strings::string('SETUP_GROUP_PLUGIN_SHOUTCASTBROWSER_DESC'),
		GroupLine => 1,
		GroupSub => 1,
		Suppress_PrefSub => 1,
		Suppress_PrefLine => 1
	);

	my %genre_options = (
		'' => '',
		name_reverse => Slim::Utils::Strings::string('SETUP_PLUGIN_SHOUTCASTBROWSER_ALPHA_REVERSE'),
		streams => Slim::Utils::Strings::string('SETUP_PLUGIN_SHOUTCASTBROWSER_NUMBEROFSTREAMS'),
		streams_reverse => Slim::Utils::Strings::string('SETUP_PLUGIN_SHOUTCASTBROWSER_NUMBEROFSTREAMS_REVERSE'),
		default => Slim::Utils::Strings::string('SETUP_PLUGIN_SHOUTCASTBROWSER_DEFAULT_ALPHA'),
		keyword => Slim::Utils::Strings::string('SETUP_PLUGIN_SHOUTCASTBROWSER_KEYWORD'),
		keyword_reverse => Slim::Utils::Strings::string('SETUP_PLUGIN_SHOUTCASTBROWSER_KEYWORD_REVERSE'),
	);

	my %stream_options = (
		'' => '',
		name_reverse => Slim::Utils::Strings::string('SETUP_PLUGIN_SHOUTCASTBROWSER_ALPHA_REVERSE'),
		listeners => Slim::Utils::Strings::string('SETUP_PLUGIN_SHOUTCASTBROWSER_NUMBEROFLISTENERS'),
		listeners_reverse => Slim::Utils::Strings::string('SETUP_PLUGIN_SHOUTCASTBROWSER_NUMBEROFLISTENERS_REVERSE'),
		default => Slim::Utils::Strings::string('SETUP_PLUGIN_SHOUTCASTBROWSER_DEFAULT_ALPHA'),
	);


	my %setupPrefs = (
		plugin_shoutcastbrowser_how_many_streams => {
 			validate => \&Slim::Web::Setup::validateInt,
 			validateArgs => [1,2000,1,2000],
			onChange => sub { %stream_data = (); }
		},
		
		plugin_shoutcastbrowser_custom_genres => {
			validate => sub { Slim::Web::Setup::validateIsFile(shift, 1); },
			PrefSize => 'large',
			onChange => sub { %stream_data = (); }
		},
		
		plugin_shoutcastbrowser_genre_criterion => {
			isArray => 1,
			arrayAddExtra => 1,
			arrayDeleteNull => 1,
			arrayDeleteValue => '',
			options => \%genre_options,
			onChange => sub {
				my ($client,$changeref,$paramref,$pageref) = @_;
				if (exists($changeref->{'plugin_shoutcastbrowser_genre_criterion'}{'Processed'})) {
					return;
				}
				Slim::Web::Setup::processArrayChange($client, 'plugin_shoutcastbrowser_genre_criterion', $paramref, $pageref);
				%stream_data = ();
				$changeref->{'plugin_shoutcastbrowser_genre_criterion'}{'Processed'} = 1;
			},
			
		},
	
		plugin_shoutcastbrowser_stream_criterion => {
			isArray => 1,
			arrayAddExtra => 1,
			arrayDeleteNull => 1,
			arrayDeleteValue => '',
			options => \%stream_options,
			onChange => sub {
				my ($client,$changeref,$paramref,$pageref) = @_;
				if (exists($changeref->{'plugin_shoutcastbrowser_stream_criterion'}{'Processed'})) {
					return;
				}
				Slim::Web::Setup::processArrayChange($client, 'plugin_shoutcastbrowser_stream_criterion', $paramref, $pageref);
				%stream_data = ();
				$changeref->{'plugin_shoutcastbrowser_stream_criterion'}{'Processed'} = 1;
			},
			
		},

		plugin_shoutcastbrowser_min_bitrate => {
			validate => \&Slim::Web::Setup::validateInt,
			validateArgs => [0, undef, 0],
			onChange => sub { %stream_data = (); }
		},
		
		plugin_shoutcastbrowser_max_bitrate => {
			validate => \&Slim::Web::Setup::validateInt,
			validateArgs => [0, undef, 0],
			onChange => sub { %stream_data = (); }
		},
		
		plugin_shoutcastbrowser_max_recent => {
			validate => \&Slim::Web::Setup::validateInt,
			validateArgs => [0, undef, 0]
		},
		
		plugin_shoutcastbrowser_max_popular => {
			validate => \&Slim::Web::Setup::validateInt,
			validateArgs => [0, undef, 0]
		},
		
		plugin_shoutcastbrowser_munge_genre => {
			validate => \&Slim::Web::Setup::validateTrueFalse,
			options  => {
				1 => string('ON'),
				0 => string('OFF')
			},
			'PrefChoose' => string('SETUP_PLUGIN_SHOUTCASTBROWSER_MUNGE_GENRE')
		}
	);
	
	return (\%setupGroup,\%setupPrefs);
}

sub checkDefaults {
	if (!Slim::Utils::Prefs::isDefined('plugin_shoutcastbrowser_how_many_streams')) {
		Slim::Utils::Prefs::set('plugin_shoutcastbrowser_how_many_streams', 300);
	}
	
	if (!Slim::Utils::Prefs::isDefined('plugin_shoutcastbrowser_genre_criterion')) {
		Slim::Utils::Prefs::set('plugin_shoutcastbrowser_genre_criterion', 'default', 0);
	}
	
	if (!Slim::Utils::Prefs::isDefined('plugin_shoutcastbrowser_stream_criterion')) {
		Slim::Utils::Prefs::set('plugin_shoutcastbrowser_stream_criterion', 'default', 0);
	}
	
	if (!Slim::Utils::Prefs::isDefined('plugin_shoutcastbrowser_min_bitrate')) {
		Slim::Utils::Prefs::set('plugin_shoutcastbrowser_min_bitrate', 0);
	}
	
	if (!Slim::Utils::Prefs::isDefined('plugin_shoutcastbrowser_max_bitrate')) {
		Slim::Utils::Prefs::set('plugin_shoutcastbrowser_max_bitrate', 0);
	}
	
	if (!Slim::Utils::Prefs::isDefined('plugin_shoutcastbrowser_max_recent')) {
		Slim::Utils::Prefs::set('plugin_shoutcastbrowser_max_recent', 50);
	}
	
	if (!Slim::Utils::Prefs::isDefined('plugin_shoutcastbrowser_max_popular')) {
		Slim::Utils::Prefs::set('plugin_shoutcastbrowser_max_popular', 40);
	}
	
	if (!Slim::Utils::Prefs::isDefined('plugin_shoutcastbrowser_munge_genre')) {
		Slim::Utils::Prefs::set('plugin_shoutcastbrowser_munge_genre', 1);
	}
}


##### Sub-mode for streams #####
# Closure for the sake of $client
sub stream_sort {
	my $client = shift;
	my $r = 0;

	for my $criterion (Slim::Utils::Prefs::getArray('plugin_shoutcastbrowser_stream_criterion')) {
		if ($criterion =~ m/^listener/i) {
			my ($aa, $bb) = (0, 0);
			
			$aa += $stream_data{getCurrentGenre($client)}{$a}{$_}[1]
				foreach keys %{ $stream_data{getCurrentGenre($client)}{$a} };
			
			$bb += $stream_data{getCurrentGenre($client)}{$b}{$_}[1]
				foreach keys %{ $stream_data{getCurrentGenre($client)}{$b} };
			
			$r = $bb <=> $aa;
		} elsif ($criterion =~ m/^name/i or $criterion =~ m/default/i) {
			$r = lc($a) cmp lc($b);
		}
		
		$r = -1 * $r if $criterion =~ m/reverse$/i;
		
		return $r if $r;
	}
	
	return $r;
};
	
my $mode_sub = sub {
	my $client = shift;

	$status{$client}{bitrate} = 0;
	$client->lines(\&streamsLines);
	$status{$client}{status} = -3;
	$status{$client}{number} = undef;
	$status{$client}{stream} = $status{$client}{old_stream}{$status{$client}{genre}};
	$client->update();

	if (getCurrentGenre($client) eq getRecentName()) {
		$status{$client}{streams} = readRecentStreamList($client) || [ $client->string('PLUGIN_SHOUTCASTBROWSER_NONE') ];
	} elsif (getCurrentGenre($client) eq getMostPopularName()) {
		$status{$client}{streams} = $genres_data{top};
	} else {
		$status{$client}{streams} = [ sort { stream_sort($client) } keys %{ $stream_data{getCurrentGenre($client)} } ];
	}
	
	$status{$client}{status} = 1;
	$client->update();
};

my $leave_mode_sub = sub {
	my $client = shift;
	$status{$client}{number} = undef;
	$status{$client}{old_stream}{$status{$client}{genre}} = $status{$client}{stream};
};

sub streamsLines {
	my $client = shift;
	my (@lines);
	
	$status{$client}{stream} ||= 0;

	if ($status{$client}{status} == 0) {
		$lines[0] = $client->string('PLUGIN_SHOUTCASTBROWSER_CONNECTING');
		$lines[1] = '';
	
	} elsif ($status{$client}{status} == -1) {
		$lines[0] = $client->string('PLUGIN_SHOUTCASTBROWSER_NETWORK_ERROR');
		$lines[1] = '';
	
	} elsif ($status{$client}{status} == -2) {
		$lines[0] = $client->string('PLUGIN_SHOUTCASTBROWSER_TOO_SOON');
		$lines[1] = '';
	
	} elsif ($status{$client}{status} == -3) {
		$lines[0] = $client->string('PLUGIN_SHOUTCASTBROWSER_SORTING');
		$lines[1] = '';
	
	} elsif ($status{$client}{status} == 1) {
		$lines[0] = $client->string('PLUGIN_SHOUTCASTBROWSER_SHOUTCAST').': '.
				getCurrentGenre($client) .
				' (' .
					($status{$client}{stream} + 1) .  ' ' .
					$client->string('OF') .  ' ' .
						getStreamCount($client) .  ') ' ;
		$lines[1] = getCurrentStreamName($client);
		
		if (keys %{ $stream_data{getCurrentGenre($client)}{getCurrentStreamName($client)} } > 1) {
			$lines[3] = Slim::Display::Display::symbol('rightarrow');
		}
	}

	return @lines;
}

sub getStreamCount {
	my $client = shift;
	return ($#{ $status{$client}{streams} } + 1);
}

sub getCurrentStreamName {
	my $client = shift;
	return @{ $status{$client}{streams} }[$status{$client}{stream}];
}

my %StreamsFunctions = (
	'up' => sub {
		my $client = shift;
		
		$status{$client}{number} = undef;
		
		$status{$client}{stream} = Slim::Buttons::Common::scroll(
						$client,
						-1,
						getStreamCount($client),
						$status{$client}{stream} || 0,
					);
		$client->update();
	},
	
	'down' => sub {
		my $client = shift;
		
		$status{$client}{number} = undef;
		
		$status{$client}{stream} = Slim::Buttons::Common::scroll(
						$client,
						1,
						getStreamCount($client),
						$status{$client}{stream} || 0,
					);
		$client->update();
	},
	
	'left' => sub {
		my $client = shift;
		Slim::Buttons::Common::popModeRight($client);
	},
	
	'right' => sub {
		my $client = shift;
	
		$status{$client}{number} = undef;
	
		if (getCurrentGenre($client) eq getRecentName()) {
			$client->bumpRight();
		} else {
			if (keys %{ $stream_data{getCurrentGenre($client)}{getCurrentStreamName($client)}} == 1) {
				Slim::Buttons::Common::pushModeLeft($client, 'ShoutcastStreamInfo');
			} else {
				Slim::Buttons::Common::pushModeLeft($client, 'ShoutcastBitrates');
			}
		
		}
	},
	
	'play' => sub {
		my $client = shift;
		if (getCurrentGenre($client) eq getRecentName()) {
			playRecentStream($client, $status{$client}{recent_data}{getCurrentStreamName($client)}, getCurrentStreamName($client), 'play');
		}
		else {
			# Add all bitrates to current playlist, but only the first one to the recently played list
			my @bitrates = sort bitrate_sort keys %{ $stream_data{getCurrentGenre($client)}{getCurrentStreamName($client)} };
			playStream($client, getCurrentGenre($client), getCurrentStreamName($client), shift @bitrates, 'play');
			
			for my $b (@bitrates) {
				playStream($client, getCurrentGenre($client), getCurrentStreamName($client), $b, 'add', 0);
			}
		}
	},
	
	'add' => sub {
		my $client = shift;
		if (getCurrentGenre($client) eq getRecentName()) {
			playRecentStream($client, $status{$client}{recent_data}{getCurrentStreamName($client)}, getCurrentStreamName($client), 'add');
		}
		else {
			for my $b (sort bitrate_sort keys %{ $stream_data{getCurrentGenre($client)}{getCurrentStreamName($client)} }) {
				playStream($client, getCurrentGenre($client), getCurrentStreamName($client), $b, 'add');
			}
		}
	},
	
	'jump_rew' => sub {
		my $client = shift;
	
		$status{$client}{number} = undef;
 		Slim::Buttons::Common::popModeRight($client);
		&reload_xml($client);
	},
	
	'numberScroll' => sub {
		my ($client, $button, $digit) = @_;
	
		if ($digit == 0 and (not $status{$client}{number})) {
			$status{$client}{stream} = 0;
		} else {
			$status{$client}{number} .= $digit;
			$status{$client}{stream} = $status{$client}{number} - 1;
		}
		
		$client->update();
	}
);

##### Sub-mode for bitrates #####

sub getBitrates {
	my $client = shift;
	return sort bitrate_sort keys %{ $stream_data{getCurrentGenre($client)}{getCurrentStreamName($client)} };
}

sub getBitrateCount {
	my $client = shift;
	my @bitrates = getBitrates($client);
	return ($#bitrates + 1);
}

sub getCurrentBitrate {
	my $client = shift;
	my @bitrates = getBitrates($client);
	return $bitrates[$status{$client}{bitrate}];
}

my $bitrate_mode_sub = sub {
	my $client = shift;
	$client->lines(\&bitrateLines);
	$client->update();
};

sub bitrate_sort {
	my $r = $b <=> $a;
	$r = -$r if SORT_BITRATE_UP;
	return $r;
}

sub bitrateLines {
	my $client = shift;
	my (@lines);

	$lines[0] = getCurrentStreamName($client);
	
	$lines[3] = ' (' . ($status{$client}{bitrate} + 1) . ' ' .
		$client->string('OF') .  ' ' .
		getBitrateCount($client) .  ')' ;

	$lines[1] = $client->string('PLUGIN_SHOUTCASTBROWSER_BITRATE') . ': ' .
		getCurrentBitrate($client) . ' ' .
		$client->string('PLUGIN_SHOUTCASTBROWSER_KBPS');
	
	return @lines;
}

my %BitrateFunctions = (
	'up' => sub {
		my $client = shift;
		$status{$client}{bitrate} = Slim::Buttons::Common::scroll(
						$client,
						-1,
						getBitrateCount($client),
						$status{$client}{bitrate} || 0,
					);
		$client->update();
	},
	
	'down' => sub {
		my $client = shift;
		$status{$client}{bitrate} = Slim::Buttons::Common::scroll(
						$client,
						1,
						getBitrateCount($client),
						$status{$client}{bitrate} || 0,
					);
		$client->update();
	},
	
	'left' => sub {
		my $client = shift;
		Slim::Buttons::Common::popModeRight($client);
	},
	
	'right' => sub {
		my $client = shift;
		Slim::Buttons::Common::pushModeLeft($client, 'ShoutcastStreamInfo');
	},
	
	'play' => sub {
		my $client = shift;
		playStream($client, getCurrentGenre($client), getCurrentStreamName($client), getCurrentBitrate($client), 'play');
	},
	
	'add' => sub {
		my $client = shift;
		playStream($client, getCurrentGenre($client), getCurrentStreamName($client), getCurrentBitrate($client), 'add');
	},
	
	'jump_rew' => sub {
		my $client = shift;
		$status{$client}{number} = undef;
		
		Slim::Buttons::Common::popModeRight($client);
		Slim::Buttons::Common::popModeRight($client);
		
		&reload_xml($client);
	},
);

##### Sub-mode for stream info #####

my $info_mode_sub = sub {
	my $client = shift;

	$status{$client}{info} = 0;
	$client->lines(\&infoLines);
	$client->update();
};

sub infoLines {
	my $client = shift;
	my @lines = ($client->string('PLUGIN_SHOUTCASTBROWSER_MODULE_NAME'), $client->string('PLUGIN_SHOUTCASTBROWSER_NONE'));
	my $current_data;
	
	if (defined getCurrentGenre($client) and defined getCurrentStreamName($client) and defined getCurrentBitrate($client)) {
		$current_data = $stream_data{getCurrentGenre($client)}{getCurrentStreamName($client)}{getCurrentBitrate($client)};
	
		my $cur = $status{$client}{info} || 0;
	
		$lines[0] = getCurrentBitrate($client) . $client->string('PLUGIN_SHOUTCASTBROWSER_KBPS') . ' - ' . getCurrentStreamName($client);
		
		$lines[1] = $info_order[$cur] . ': ';
		# get the stream's name from the hash key, not the array
		if ($info_index[$cur] == -1) {
			$lines[1] .= getCurrentStreamName($client);
		}
		else {
			$lines[1] .= $current_data->[$info_index[$cur]] || $client->string('PLUGIN_SHOUTCASTBROWSER_NONE');
		}
	}

	return @lines;
}

my %InfoFunctions = (
	'up' => sub {
		my $client = shift;
		
		$status{$client}{info} = Slim::Buttons::Common::scroll(
						$client,
						-1,
						$#info_order + 1,
						$status{$client}{info} || 0,
					);
		$client->update();
	},
	
	'down' => sub {
		my $client = shift;
		
		$status{$client}{info} = Slim::Buttons::Common::scroll(
						$client,
						1,
						$#info_order + 1,
						$status{$client}{info} || 0,
					);
		$client->update();
	},
	
	'left' => sub {
		my $client = shift;
		Slim::Buttons::Common::popModeRight($client);
	},
	
	'right' => sub {
		my $client = shift;
		$client->bumpRight();
	},
	
	'play' => sub {
		my $client = shift;
		playStream($client, getCurrentGenre($client), getCurrentStreamName($client), getCurrentBitrate($client), 'play');
	},
	
	'add' => sub {
		my $client = shift;
		playStream($client, getCurrentGenre($client), getCurrentStreamName($client), getCurrentBitrate($client), 'add');
	},
	
	'jump_rew' => sub {
		my $client = shift;
		$status{$client}{number} = undef;
		
		Slim::Buttons::Common::popModeRight($client);
		Slim::Buttons::Common::popModeRight($client);
		Slim::Buttons::Common::popModeRight($client);
		
		&reload_xml($client);
	},
);

sub playStream {
	my ($client, $currentGenre, $currentStream, $currentBitrate, $method, $addToRecent) = @_;
	my $current_data = $stream_data{$currentGenre}{$currentStream}{$currentBitrate};
	Slim::Control::Command::execute($client, ['playlist', $method, $current_data->[0], $currentStream]);
	unless (defined $addToRecent && not $addToRecent) {
		writeRecentStreamList($client, $currentStream, $currentBitrate, $current_data);
	}
}

sub playRecentStream {
	my ($client, $url, $currentStream, $method) = @_;
	writeRecentStreamList($client, $currentStream, undef, [ $url ]);
	if ($currentStream =~ /\d+ \w+?: (.*)/i) {
		$currentStream = $1;
	}
	Slim::Control::Command::execute($client, ['playlist', $method, $url, $currentStream]);
	$status{$client}{streams} = readRecentStreamList($client) || [ $client->string('PLUGIN_SHOUTCASTBROWSER_NONE') ];
	$status{$client}{stream} = 0;
}

sub getRecentFilename {
	my $client = shift;
	
	unless ($status{$client}{recent_filename}) {
		my $recentDir;
		if (Slim::Utils::Prefs::get('playlistdir')) {
			$recentDir = catdir(Slim::Utils::Prefs::get('playlistdir'), RECENT_DIRNAME);
			mkdir $recentDir unless (-d $recentDir);
		}
		$status{$client}{recent_filename} = catfile($recentDir, $client->name() . '.m3u') if defined $recentDir;
	}
	
	return $status{$client}{recent_filename};
}

sub readRecentStreamList {
	my $client = shift;

	my @recent = ();
	unless (defined $client && open(FH, getRecentFilename($client))) {
		# if there's no client, we can't display a client specific list...
		return undef;
	};

	# Using Slim::Formats::Parse::M3U is unreliable, since it
	# forces us to use Slim::Music::Info::title to get the
	# title, but Info.pm may refuse to give it to us if it
	# thinks the data is "invalid" or something.  Also, we
	# want a list of titles with URLs attached, not vice
	# versa.
	my $title;
	
	while (my $entry = <FH>) {
		chomp($entry);
		$entry =~ s/^\s*(\S.*\S)\s*$/$1/sg;

		if ($entry =~ /^#EXTINF:.*?,(.*)$/) {
			$title = $1;
		}

		next if ($entry =~ /^#/ || not $entry);

		if (defined($title)) {
			$status{$client}{recent_data}{$title} = $entry;
			push @recent, $title;
			$title = undef;
		}
	}

	close FH;
	return [ @recent ];
}

sub writeRecentStreamList {
	my ($client, $streamname, $bitrate, $data) = @_;
	
	return if not defined $client;
	
	$streamname = "$bitrate kbps: $streamname" if (defined $bitrate);
	$status{$client}{recent_data}{$streamname} = $data->[0];

	my @recent;
	if (exists $status{$client}{recent_data}) {
		@recent = keys %{ $status{$client}{recent_data} };
	} else {
		@recent = @{ readRecentStreamList($client) };
	}

	# put current stream at the top of the list if already in the list	
	my ($i) = grep $recent[$_] eq $streamname, 0..$#recent;
	
	if (defined $i) {
		splice @recent, $i, 1;
		unshift @recent, $streamname;
	} else {
		unshift @recent, $streamname;
		pop @recent if @recent > Slim::Utils::Prefs::get('plugin_shoutcastbrowser_max_recent');
	}

	if (defined getRecentFilename($client)) {
		open(FH, ">" . getRecentFilename($client)) or do {
#			print STDERR "Could not open " . getRecentFilename($client) . " for writing.\n";
			return;
		};
	
		print FH "#EXTM3U\n";
		foreach my $name (@recent) {
			print FH "#EXTINF:-1,$name\n";
			print FH $status{$client}{recent_data}{$name} . "\n";
		}
		close FH;
	}
}



# Add extra modes
Slim::Buttons::Common::addMode('ShoutcastStreams', \%StreamsFunctions, $mode_sub, $leave_mode_sub);
Slim::Buttons::Common::addMode('ShoutcastBitrates', \%BitrateFunctions, $bitrate_mode_sub);
Slim::Buttons::Common::addMode('ShoutcastStreamInfo', \%InfoFunctions, $info_mode_sub);


# Web pages

sub webPages {
    my %pages = ("index\.htm" => \&handleWebIndex);
	Slim::Web::Pages::addLinks("radio", { 'PLUGIN_SHOUTCASTBROWSER_MODULE_NAME' => "plugins/ShoutcastBrowser/index.html" });
    return (\%pages);
}

sub handleWebIndex {
	my ($client, $params) = @_;

	if (loadStreamList($client)) {
		if (defined $params->{'genreID'}) {
			$params->{'genre'} = @{$genres_data{genres}}[$params->{'genreID'}];

			# play/add stream
			if (defined $params->{'action'} && ($params->{'action'} =~ /(add|play|insert|delete)/i)) {
				my $myStream = @{ getWebStreamList($client, $params->{'genre'}) }[$params->{'streamID'}];
				
				if ($params->{'genre'} eq getRecentName()) {
					playRecentStream($client, $status{$client}{recent_data}{$myStream}, $myStream, $params->{'action'});
				}
				else {
					playStream($client, $params->{'genre'}, $myStream, $params->{'bitrate'}, $params->{'action'});
				}
			}
	
			# show stream information
			if (defined $params->{'action'} && ($params->{'action'} eq 'info')) {
				my @mystreams = @{ getWebStreamList($client, $params->{'genre'}) };
				$params->{'stream'} = $mystreams[$params->{'streamID'}];
				$params->{'streaminfo'} = $stream_data{getAllName()}{$params->{'stream'}}{$params->{'bitrate'}};
			} 
			# show streams of the wanted genre
			else {
				$params->{'mystreams'} = getWebStreamList($client, $params->{'genre'});
				# we don't have any information about recent streams -> fill in some fake values
				if ($params->{'genre'} eq getRecentName()) {
					if (defined @{$params->{'mystreams'}}) {
						foreach (@{$params->{'mystreams'}}) {
							$params->{'streams'}->{$_}->{'0'} = ();
						}
					}
					else {
						$params->{'streams'} = 1;
						$params->{'msg'} = string('PLUGIN_SHOUTCASTBROWSER_NONE');
					}
				}
				else {
					$params->{'streams'} = \%{ $stream_data{$params->{'genre'}} };
				}
			}
		}
		# show genre list
		else {
			$params->{'genres'} = $genres_data{genres};
		}
	}
	else {
		$params->{'msg'} = string('PLUGIN_SHOUTCASTBROWSER_NETWORK_ERROR');
	}

	return Slim::Web::HTTP::filltemplatefile('plugins/ShoutcastBrowser/index.html', $params);
}

sub getWebStreamList {
	my ($client, $genre) = @_;
	if ($genre eq getMostPopularName()) {
		return $genres_data{top};
	}
	elsif ($genre eq getRecentName()) {
		return readRecentStreamList($client);
	}
	else {
		return [ sort { stream_sort($client) } keys %{ $stream_data{$genre} } ];
	}
}


sub strings {
	return q^PLUGIN_SHOUTCASTBROWSER_MODULE_NAME
	EN	SHOUTcast Internet Radio
	ES	Radio por Internet SHOUTcast

PLUGIN_SHOUTCASTBROWSER_GENRES
	DE	SHOUTcast Musikstile
	EN	SHOUTcast Internet Radio
	ES	Radio por Internet SHOUTcast

PLUGIN_SHOUTCASTBROWSER_CONNECTING
	DE	Verbinde mit SHOUTcast...
	EN	Connecting to SHOUTcast...
	ES	Conectando a SHOUTcast...

PLUGIN_SHOUTCASTBROWSER_NETWORK_ERROR
	DE	Fehler: SHOUTcast Web-Seite nicht verfügbar
	EN	Error: SHOUTcast web site not available
	ES	Error: el sitio web de SHOUTcast no está disponible

PLUGIN_SHOUTCASTBROWSER_SHOUTCAST
	EN	SHOUTcast

PLUGIN_SHOUTCASTBROWSER_ALL_STREAMS
	DE	Alle Streams
	EN	All Streams
	ES	Todos los streams

PLUGIN_SHOUTCASTBROWSER_NONE
	DE	Keine
	EN	None
	ES	Ninguno

PLUGIN_SHOUTCASTBROWSER_BITRATE
	EN	Bitrate
	ES	Tasa de bits

PLUGIN_SHOUTCASTBROWSER_KBPS
	EN	kbps

PLUGIN_SHOUTCASTBROWSER_RECENT
	DE	Kürzlich gehört
	EN	Recently played
	ES	Recientemente escuchado

PLUGIN_SHOUTCASTBROWSER_MOST_POPULAR
	DE	Populäre Streams
	EN	Most Popular
	ES	Más Popular

PLUGIN_SHOUTCASTBROWSER_MISC
	DE	Diverse Stile
	EN	Misc. genres
	ES	Géneros misceláneos

PLUGIN_SHOUTCASTBROWSER_TOO_SOON
	DE	Versuche es in einer Minute wieder
	EN	Try again in a minute
	ES	Volver a intentar en un minuto

PLUGIN_SHOUTCASTBROWSER_SORTING
	DE	Sortiere Streams...
	EN	Sorting streams ...
	ES	Ordenando streams...

PLUGIN_SHOUTCASTBROWSER_WAS_PLAYING
	DE	Spielte zuletzt
	EN	Was playing

PLUGIN_SHOUTCASTBROWSER_STREAM_NAME
	EN	Name

SETUP_GROUP_PLUGIN_SHOUTCASTBROWSER
	EN	SHOUTcast Internet Radio
	ES	Radio por Internet SHOUTcast

SETUP_GROUP_PLUGIN_SHOUTCASTBROWSER_DESC
	DE	Blättere durch die Liste der SHOUTcast Internet Radiostationen. Drücke nach jedem Einstellungswechsel REW, um die Liste neu zu laden.
	EN	Browse SHOUTcast list of Internet Radio streams.  Hit rewind after changing any settings to reload the list of streams.
	ES	Recorrer la lista de streams de Radio por Internet de  SHOUTcast. Presionar rewind después de cambiar la configuración, para recargar la lista de streams.

SETUP_PLUGIN_SHOUTCASTBROWSER_HOW_MANY_STREAMS
	DE	Anzahl Streams
	EN	Number of Streams
	ES	Número de Streams

SETUP_PLUGIN_SHOUTCASTBROWSER_HOW_MANY_STREAMS_DESC
	DE	Anzahl aufzulistender Streams (Radiostationen). Voreinstellung ist 300, das Maximum 2000.
	EN	How many streams to get.  Default is 300, maximum is 2000.
	ES	Cuántos streams traer. Por defecto es 300, máximo es 2000.

SETUP_PLUGIN_SHOUTCASTBROWSER_GENRE_CRITERION
	DE	Sortierkriterium für Musikstile
	EN	Sort Criterion for Genres
	ES	Criterio para Ordenar por Géneros

SETUP_PLUGIN_SHOUTCASTBROWSER_GENRE_CRITERION_DESC
	DE	Kriterium für die Sortierung der Musikstile
	EN	Criterion for sorting genres.
	ES	Criterio para Ordenar por Géneros

SETUP_PLUGIN_SHOUTCASTBROWSER_STREAM_CRITERION
	DE	Sortierkriterium für Streams
	EN	Sort Criterion for Streams
	ES	Criterio para ordenar streams.

SETUP_PLUGIN_SHOUTCASTBROWSER_STREAM_CRITERION_DESC
	DE	Kriterium für die Sortierung der Streams (Radiostationen)
	EN	Criterion for sorting streams.
	ES	Criterio para ordenar streams.

SETUP_PLUGIN_SHOUTCASTBROWSER_MIN_BITRATE
	DE	Minimale Bitrate
	EN	Minimum Bitrate
	ES	Mínima Tasa de Bits

SETUP_PLUGIN_SHOUTCASTBROWSER_MIN_BITRATE_DESC
	DE	Minimal erwünschte Bitrate (0 für unbeschränkt).
	EN	Minimum Bitrate in which you are interested (0 for no limit).
	ES	Mínima Tasa de Bits que nos interesa (0 para no tener límite).

SETUP_PLUGIN_SHOUTCASTBROWSER_MAX_BITRATE
	DE	Maximale Bitrate
	EN	Maximum Bitrate
	ES	Máxima Tasa de Bits

SETUP_PLUGIN_SHOUTCASTBROWSER_MAX_BITRATE_DESC
	DE	Maximal erwünschte Bitrate (0 für unbeschränkt).
	EN	Maximum Bitrate in which you are interested (0 for no limit).
	ES	Máxima Tasa de Bits que nos interesa (0 para no tener límite).

SETUP_PLUGIN_SHOUTCASTBROWSER_MAX_RECENT
	DE	Zuletzt gehörte Streams
	EN	Recent Streams
	ES	Streams recientes

SETUP_PLUGIN_SHOUTCASTBROWSER_MAX_RECENT_DESC
	DE	Anzahl zu merkender Streams (Radiostationen)
	EN	Maximum number of recently played streams to remember.
	ES	Máximo número a recordar de streams escuchados recientemente.

SETUP_PLUGIN_SHOUTCASTBROWSER_MAX_POPULAR
	DE	Populäre Streams
	EN	Most Popular
	ES	Más Popular

SETUP_PLUGIN_SHOUTCASTBROWSER_MAX_POPULAR_DESC
	DE	Die Anzahl Streams, die unter "Populäre Streams" aufgeführt werden sollen. Die Beliebtheit misst sich an der Anzahl Hörer aller Bitraten.
	EN	Number of streams to include in the category of most popular streams, measured by the total of all listeners at all bitrates.
	ES	Número de streams a incluir en la categoría de streams más populares, medida por el total de oyentes en todas las tasas de bits.

SETUP_PLUGIN_SHOUTCASTBROWSER_CUSTOM_GENRES
	DE	Eigene Musikstil-Definitionen
	EN	Custom Genre Definitions
	ES	Definiciones Personalizadas de Géneros

SETUP_PLUGIN_SHOUTCASTBROWSER_CUSTOM_GENRES_DESC
	DE	Sie können eigene SHOUTcast-Kategorien definieren, indem Sie hier eine Datei mit den eigenen Musikstil-Definitionen angeben. Jede Zeile dieser Datei bezeichnet eine Kategorie, und besteht aus einer Serie von Ausdrücken, die durch Leerzeichen getrennt sind. Der erste Ausdruck ist der Name des Musikstils, alle folgenden bezeichnen ein Textmuster, das mit diesem Musikstil assoziiert wird. Jeder Stream, dessen Stil eines dieser Textmuster enthält, wird diesem Musikstil zugeordnet. Leerzeichen innerhalb eines Begriffs können durch Unterstriche (_) definiert werden. Gross-/Kleinschreibung ist irrelevant.
	EN	You can define your own SHOUTcast categories by indicating the name of a custom genre definition file here.  Each line in this file defines a category per line, and each line consists of a series of terms separated by whitespace.  The first term is the name of the genre, and each subsequent term is a pattern associated with that genre.  If any of these patterns matches the advertised genre of a stream, that stream is considered to belong to that genre.  You may use an underscore to represent a space within any of these terms, and in the patterns, case does not matter.
	ES	Se pueden definir categorías propias para SHOUTcast, indicando el nombre de un archivo de definición de géneros propio aquí. Cada línea de este archivo define una categoría, y cada línea consiste de una serie de términos separados por espacions en blanco. El primer término es el nombre del género, y cada término subsiguiente es un patrón asociado a ese género. Si cualquiera de estos patrones concuerda con el género promocionado de un stream, se considerará que ese stream pertenece a ese género. Se puede utilizar un guión bajo (un derscore) para representar un espacio dentro de estos términos, y no hay distinción de mayúsculas y minúsculas en los patrones.

SETUP_PLUGIN_SHOUTCASTBROWSER_ALPHA_REVERSE
	DE	Alphabetisch (umgekehrte Reihenfolge)
	EN	Alphabetical (reverse)
	ES	Alfabético (reverso)

SETUP_PLUGIN_SHOUTCASTBROWSER_NUMBEROFSTREAMS
	DE	Anzahl Streams
	EN	Number of streams
	ES	Número de streams

SETUP_PLUGIN_SHOUTCASTBROWSER_NUMBEROFSTREAMS_REVERSE
	DE	Anzahl Streams (umgekehrte Reihenfolge)
	EN	Number of streams (reverse)
	ES	Número de Streams (reverso)

SETUP_PLUGIN_SHOUTCASTBROWSER_DEFAULT_ALPHA
	DE	Standard (alphabetisch)
	EN	Default (alphabetical)
	ES	Por Defecto ( alfabético)

SETUP_PLUGIN_SHOUTCASTBROWSER_NUMBEROFLISTENERS
	DE	Anzahl Hörer
	EN	Number of listeners
	ES	Número de oyentes

SETUP_PLUGIN_SHOUTCASTBROWSER_LISTENERS
	DE	Hörer
	EN	Listeners
	ES	Oyentes

SETUP_PLUGIN_SHOUTCASTBROWSER_NUMBEROFLISTENERS_REVERSE
	DE	Anzahl Hörer (umgekehrte Reihenfolge)
	EN	Number of listeners (reverse)
	ES	Número de oyentes (reverso)

SETUP_PLUGIN_SHOUTCASTBROWSER_KEYWORD
	DE	Definitions-Reihenfolge
	EN	Order of definition
	ES	Orden de definición

SETUP_PLUGIN_SHOUTCASTBROWSER_KEYWORD_REVERSE
	DE	Definitions-Reihenfolge (umgekehrt)
	EN	Order of definition (reverse)
	ES	Orden de definición (reverso)

SETUP_PLUGIN_SHOUTCASTBROWSER_MUNGE_GENRE
	DE	Musikstile normalisieren
	EN	Normalise genres

SETUP_PLUGIN_SHOUTCASTBROWSER_MUNGE_GENRE_DESC
	DE	Standardmässig wird versucht, die Musikstile zu normalisieren, weil sonst beinahe so viele Stile wie Streams aufgeführt werden. Falls Sie alle Stile unverändert aufführen wollen, so deaktivieren Sie diese Option.
	EN	By default, genres are normalised based on keywords, because otherwise there are nearly as many genres as there are streams. If you would like to see the genre listing as defined by each stream, turn off this parameter.^;
}

1;

