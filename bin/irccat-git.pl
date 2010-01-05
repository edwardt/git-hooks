#!/usr/bin/perl

use strict;
use warnings;

use Getopt::Long;

my $result = GetOptions(
    "refname=s"     => \(my $refname),
    "oldrev=s"      => \(my $oldrev),
    "newrev=s"      => \(my $newrev),
);

my @branches    = split(':', `git config irccat.branches` || '');
my $recipients  = `git config irccat.recipients` || '#*';
my $repo        = `git config notify.name`;
my $graph_lines = `git config irccat.graphLines` || 13;
my $format      = `git config irccat.commitFormat` || 'format:"%h %s"';

return unless $result;

if (_should_show_ref($refname)) {
    my $new_nodes = `git rev-list ^$oldrev $newrev | wc -l`;
    chomp $new_nodes;

    chomp $format;

    my $log_graph = `git log --pretty=$format --graph ^$oldrev $newrev`;

    my ($name) = $refname =~ m{^refs/.*?/(.*)$};
    $oldrev =~ s/^(.{8}).*/$1/;
    $newrev =~ s/^(.{8}).*/$1/;

    my @output_lines = split("\n",
        "$recipients $repo ($name): Updated $oldrev => $newrev ($new_nodes commits)\n"
        . ($graph_lines > 0 ? $log_graph : '')
    );
    @output_lines = (@output_lines[0..($graph_lines - 1)], "...")
            if $graph_lines > 0 && @output_lines > $graph_lines;

    print join("\n", @output_lines) . "\n";
}

sub _should_show_ref
{
    return 1 if @branches == 0;

    my $ref = shift;
    elsif (scalar grep { $ref =~ qr{^refs/.*/$_$} } @branches) {
        return 1;
    }

    return 0
}
