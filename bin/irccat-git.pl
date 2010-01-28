#!/usr/bin/perl

use strict;
use warnings;

use IO::Socket;

$|++;

sub get_config_var($)
{
    my $key = shift;
    my $value = `git config $key`;
    chomp($value);

    return $value;
}

my $should_notify = get_config_var('irccat.enabled') || 0;

exit 0 unless $should_notify;

my $refname = $ARGV[0];
my $oldrev  = $ARGV[1];
my $newrev  = $ARGV[2];

my @branches    = split(':', get_config_var('irccat.branches') || '');
my $recipients  = get_config_var('irccat.recipients') || '#*';
my $repo        = get_config_var('notify.name');
my $graph_lines = get_config_var('irccat.graphLines') || 13;
my $format      = get_config_var('irccat.commitFormat') || q|format:'(%h) %cN - %s'|;
my $irccat_host = get_config_var('irccat.host');
my $irccat_port = get_config_var('irccat.port');

exit 1 unless defined $refname && $irccat_host;

if (_should_show_ref($refname)) {
    my ($name) = $refname =~ m{^refs/.*?/(.*)$};

    my $message = "$recipients $repo ($name): ";

    if ($newrev eq '0' x 40) {
        print "irccat: Deleted a branch.\n";
        $message .= _deleted_ref_content();
    } elsif ($oldrev eq '0' x 40) {
        print "irccat: Created a branch.\n";
        $message .= _created_ref_content();
    } else {
        print "irccat: Updated a branch.\n";
        $message .= _updated_ref_content();
    }

    my $sock = IO::Socket::INET->new(
        PeerAddr => $irccat_host,
        PeerPort => $irccat_port,
        Proto    => 'tcp',
    );

    print $sock $message;
}

sub _should_show_ref
{
    return 1 if @branches == 0;

    my $ref = shift;
    if (scalar grep { $ref =~ qr{^$_$} } @branches) {
        return 1;
    }

    return 0
}

sub _updated_ref_content
{
    my $new_nodes = `git rev-list ^$oldrev $newrev | wc -l`;
    chomp $new_nodes;

    chomp $format;

    my $log_graph = `git log --pretty=$format --graph ^$oldrev $newrev`;

    $oldrev = _short_rev($oldrev);
    $newrev = _short_rev($newrev);

    my @output_lines = (
        "Updated $oldrev => $newrev ($new_nodes commits)",
        split("\n", ($graph_lines > 0 ? $log_graph : '')),
    );

    @output_lines = (@output_lines[0..($graph_lines - 1)], "...")
            if $graph_lines > 0 && @output_lines > $graph_lines;

    return join("\n", @output_lines) . "\n"
}

sub _deleted_ref_content
{
    my $old_commit = `git log -1 --pretty=$format $oldrev`;
    chomp $old_commit;

    return "Deleted branch. Was: $old_commit\n";
}

sub _created_ref_content
{
    my $new_commit = `git log -1 --pretty=$format $newrev`;
    chomp $new_commit;

    return "Created. $new_commit\n";
}

sub _short_rev
{
    my $short = shift;
    $short =~ s/^(.{8}).*/$1/;
    return $short;
}

