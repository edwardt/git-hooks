#!/usr/bin/perl

use strict;
use warnings;

use Getopt::Long;

my $refname;
my $oldrev;
my $newrev;
my @branches;
my $recipients = "#*";
my $repo;
my $graph_lines = 13;
my $default_format = 'format:"%h %s"';
my $result = GetOptions(
    "refname=s"     => \$refname,
    "oldrev=s"      => \$oldrev,
    "newrev=s"      => \$newrev,
    "branch|b=s@"   => \@branches,
    "recipients=s"  => \$recipients,
    "repo=s"        => \$repo,
    "graph-lines=s" => \$graph_lines,
);

return unless $result;

if (_should_show_ref($refname)) {
    my $new_nodes = `git rev-list ^$oldrev $newrev | wc -l`;
    chomp $new_nodes;

    my $format = `git config irccat.commitFormat`;
    $format = $default_format if ($?);
    chomp $format;

    my $log_graph = `git log --pretty=$format --graph ^$oldrev $newrev | head -n$graph_lines`;

    my ($name) = $refname =~ m{^refs/.*?/(.*)$};
    $oldrev =~ s/^(.{8}).*/$1/;
    $newrev =~ s/^(.{8}).*/$1/;

    my $message = "$recipients $repo ($name): Updated $oldrev => $newrev ($new_nodes commits)\n"
        . $log_graph;
    my @output_lines = split("\n", $log_graph);
    $message .= "...\n" if scalar @output_lines > $graph_lines;

    print $message;
}

sub _should_show_ref
{
    my $ref = shift;

    if (@branches == 0) {
        return 1;
    }
    elsif (scalar grep { $ref =~ qr{^refs/.*/$_$} } @branches) {
        return 1;
    }

    return 0
}
