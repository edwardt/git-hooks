#!/usr/bin/perl
#
# Tool to send git commit notifications
#
# Copyright 2005 Alexandre Julliard
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; either version 2 of
# the License, or (at your option) any later version.
#
#
# This script is meant to be called from .git/hooks/update.
#
# Usage: git-notify [options] [--] refname old-sha1 new-sha1
#
#   -c name   Send CIA notifications under specified project name
#   -m addr   Send mail notifications to specified address
#   -n max    Set max number of individual mails to send
#   -r name   Set the git repository name
#   -s bytes  Set the maximum diff size in bytes (-1 for no limit)
#   -u url    Set the URL to the gitweb browser
#   -x branch Exclude changes to the specified branch from reports
#

use strict;
use warnings;

$|++;

use open ':utf8';
use Encode 'encode';
use Cwd 'realpath';

binmode STDIN, ':utf8';
binmode STDOUT, ':utf8';

# See if we need to run at all.
my $cia_enabled   = `git config notify.cia.enabled` || 0;
my $email_enabled = `git config notify.email.enabled` || 0;
exit 0 unless $cia_enabled || $email_enabled;

# base URL of the gitweb repository browser (can be set with the -u option)
my $gitweb_url = `git config notify.gitwebUrl` || 'http://rtkgit.rtkinternal/';

# set this to something that takes "-s"
my $mailer = '/bin/mail';

my $sender = `git config notify.email.sender` || 'git@rtkgit.rtkinternal';

# default repository name (can be changed with the -r option)
my $repos_name = `git config notify.name` || '';

# max size of diffs in bytes (can be changed with the -s option)
my $max_diff_size = `git config notify.diffBytes` || 10000;

# address for mail notices (can be set with -m option)
my $commitlist_address = `git config notify.email.address`;

# project name for CIA notices (can be set with -c option)
my $cia_project_name = `git config notify.cia.name`;

# CIA notification address
my $cia_address = `git config notify.cia.address` || 'cia@cia.navi.cx';

# max number of individual notices before falling back to a single global notice (can be set with -n option)
my $max_individual_notices = `git config notify.email.max` || 100;

# debug mode
my $debug = `git config notify.debug` || 0;

# branches to exclude
my @exclude_list = split(':', `git config notify.branchExclude` || '');

sub usage()
{
    print "Usage: $0 [options] [--] refname old-sha1 new-sha1\n";
    print "   git config notify.cia.enabled                       Enable sending CIA notifications\n";
    print "   git config notify.email.enabled                     Enable sending email notifications\n";
    print "   git config notify.cia.name name                     Send CIA notifications under specified project name\n";
    print "   git config notify.cia.address cia\@cia.navi.cx       Send CIA notifications to the specified email address\n";
    print "   git config notify.email.address addr\@example.com    Send mail notifications to specified address\n";
    print "   git config notify.email.sender addr\@example.com     Send mail notifications from specified address\n";
    print "   git config notify.email.max 100                     Set max number of individual mails to send\n";
    print "   git config notify.name name                         Set the git repository name\n";
    print "   git config notify.diffBytes 10000                   Set the maximum diff size in bytes (-1 for no limit)\n";
    print "   git config notify.gitwebUrl http://url/gitweb.cgi   Set the URL to the gitweb browser\n";
    print "   git config notify.branchExclude pu:next:foo:bar:baz Exclude changes to the specified branche prefixes from reports. Colon separated list.\n";
    print "   git config notify.debug 1                           Turn on debugging.\n";
    exit 1;
}

sub xml_escape($)
{
    my $str = shift;
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    my @chars = unpack "U*", $str;
    $str = join "", map { ($_ > 127) ? sprintf "&#%u;", $_ : chr($_); } @chars;
    return $str;
}

# format an integer date + timezone as string
# algorithm taken from git's date.c
sub format_date($$)
{
    my ($time,$tz) = @_;

    if ($tz < 0)
    {
        my $minutes = (-$tz / 100) * 60 + (-$tz % 100);
        $time -= $minutes * 60;
    }
    else
    {
        my $minutes = ($tz / 100) * 60 + ($tz % 100);
        $time += $minutes * 60;
    }
    return gmtime($time) . sprintf " %+05d", $tz;
}

# parse command line options
sub parse_options()
{
    if (!@ARGV || $#ARGV != 2) { usage(); }
}

# send an email notification
sub mail_notification($$$@)
{
    my ($name, $subject, $content_type, @text) = @_;
    $subject = encode("MIME-Q",$subject);
    if ($debug)
    {
        print "---------------------\n";
        print "To: $name\n";
        print "Subject: $subject\n";
        print "Content-Type: $content_type\n";
        print "\n", join("\n", @text), "\n";
    }
    else
    {
        my $pid = open MAIL, "|-";
        return unless defined $pid;
        if (!$pid)
        {
            #exec $mailer, "-s", $subject, "-a", "Content-Type: $content_type", $name, "--", "-f", $sender or die "Cannot exec $mailer";
            exec $mailer, "-s", $subject, $name, "--", "-f", $sender or die "Cannot exec $mailer";
        }
        print MAIL join("\n", @text), "\n";
        close MAIL;
    }
}

# get the default repository name
sub get_repos_name()
{
    my $dir = `git rev-parse --git-dir`;
    chomp $dir;
    my $repos = realpath($dir);
    $repos =~ s/(.*?)((\.git\/)?\.git)$/\1/;
    $repos =~ s/(.*)\/([^\/]+)\/?$/\2/;
    return $repos;
}

# extract the information from a commit or tag object and return a hash containing the various fields
sub get_object_info($)
{
    my $obj = shift;
    my %info = ();
    my @log = ();
    my $do_log = 0;

    open TYPE, "-|" or exec "git", "cat-file", "-t", $obj or die "cannot run git-cat-file";
    my $type = <TYPE>;
    chomp $type;
    close TYPE;

    open OBJ, "-|" or exec "git", "cat-file", $type, $obj or die "cannot run git-cat-file";
    while (<OBJ>)
    {
        chomp;
        if ($do_log)
        {
            last if /^-----BEGIN PGP SIGNATURE-----/;
            push @log, $_;
        }
        elsif (/^(author|committer|tagger) ((.*)(<.*>)) (\d+) ([+-]\d+)$/)
        {
            $info{$1} = $2;
            $info{$1 . "_name"} = $3;
            $info{$1 . "_email"} = $4;
            $info{$1 . "_date"} = $5;
            $info{$1 . "_tz"} = $6;
        }
        elsif (/^tag (.*)$/)
        {
            $info{"tag"} = $1;
        }
        elsif (/^$/) { $do_log = 1; }
    }
    close OBJ;

    $info{"type"} = $type;
    $info{"log"} = \@log;
    return %info;
}

# send a commit notice to a mailing list
sub send_commit_notice($$)
{
    print "Sending email notifications: ";

    my ($ref,$obj) = @_;
    my %info = get_object_info($obj);
    my @notice = ();
    my $subject;

    if ($info{"type"} eq "tag")
    {
        push @notice,
        "Module: $repos_name",
        "Branch: $ref",
        "Tag:    $obj",
        "URL:    $gitweb_url;a=tag;h=$obj",
        "",
        "Tagger: " . $info{"tagger"},
        "Date:   " . format_date($info{"tagger_date"},$info{"tagger_tz"}),
        "",
        join "\n", @{$info{"log"}};
        $subject = "Tag " . $info{"tag"} . " : " . $info{"tagger_name"} . ": " . ${$info{"log"}}[0];
    }
    else
    {
        push @notice,
        "Module: $repos_name",
        "Branch: $ref",
        "Commit: $obj",
        "URL:    $gitweb_url;a=commit;h=$obj",
        "",
        "Author: " . $info{"author"},
        "Date:   " . format_date($info{"author_date"},$info{"author_tz"}),
        "",
        join "\n", @{$info{"log"}},
        "",
        "---",
        "";

        open STAT, "-|" or exec "git", "diff-tree", "--stat", "-M", "--no-commit-id", $obj or die "cannot exec git-diff-tree";
        push @notice, join("", <STAT>);
        close STAT;

        open DIFF, "-|" or exec "git", "diff-tree", "-p", "-M", "--no-commit-id", $obj or die "cannot exec git-diff-tree";
        my $diff = join( "", <DIFF> );
        close DIFF;

        if (($max_diff_size == -1) || (length($diff) < $max_diff_size))
        {
            push @notice, $diff;
        }
        else
        {
            push @notice, "Diff:   $gitweb_url;a=commitdiff;h=$obj",
        }

        $subject = $info{"author_name"} . ": " . ${$info{"log"}}[0];
    }

    mail_notification($commitlist_address, $subject, "text/plain; charset=UTF-8", @notice);
    print "DONE\n";
}

# send a commit notice to the CIA server
sub send_cia_notice($$)
{
    print "Sending cia notifications: ";

    my ($ref,$commit) = @_;
    my %info = get_object_info($commit);
    my @cia_text = ();

    return if $info{"type"} ne "commit";

    push @cia_text,
        "<message>",
        "  <generator>",
        "    <name>git-notify script for CIA</name>",
        "  </generator>",
        "  <source>",
        "    <project>" . xml_escape($cia_project_name) . "</project>",
        "    <module>" . xml_escape($repos_name) . "</module>",
        "    <branch>" . xml_escape($ref). "</branch>",
        "  </source>",
        "  <body>",
        "    <commit>",
        "      <revision>" . substr($commit,0,10) . "</revision>",
        "      <author>" . xml_escape($info{"author"}) . "</author>",
        "      <log>" . xml_escape(join "\n", @{$info{"log"}}) . "</log>",
        "      <files>";

    open COMMIT, "-|" or exec "git", "diff-tree", "--name-status", "-r", "-M", $commit or die "cannot run git-diff-tree";
    while (<COMMIT>)
    {
        chomp;
        if (/^([AMD])\t(.*)$/)
        {
            my ($action, $file) = ($1, $2);
            my %actions = ( "A" => "add", "M" => "modify", "D" => "remove" );
            next unless defined $actions{$action};
            push @cia_text, "        <file action=\"$actions{$action}\">" . xml_escape($file) . "</file>";
        }
        elsif (/^R\d+\t(.*)\t(.*)$/)
        {
            my ($old, $new) = ($1, $2);
            push @cia_text, "        <file action=\"rename\" to=\"" . xml_escape($new) . "\">" . xml_escape($old) . "</file>";
        }
    }
    close COMMIT;

    push @cia_text,
        "      </files>",
        "      <url>" . xml_escape("$gitweb_url;a=commit;h=$commit") . "</url>",
        "    </commit>",
        "  </body>",
        "  <timestamp>" . $info{"author_date"} . "</timestamp>",
        "</message>";

    mail_notification($cia_address, "DeliverXML", "text/xml", @cia_text);
    print "DONE\n";
}

# send a global commit notice when there are too many commits for individual mails
sub send_global_notice($$$)
{
    my ($ref, $old_sha1, $new_sha1) = @_;
    my @notice = ();

    open LIST, "-|" or exec "git", "rev-list", "--pretty", "^$old_sha1", "$new_sha1", (map { "^$_" } @exclude_list) or die "cannot exec git-rev-list";
    while (<LIST>)
    {
        chomp;
        s/^commit /URL:    $gitweb_url;?a=commit;h=/;
        push @notice, $_;
    }
    close LIST;

    mail_notification($commitlist_address, "New commits on branch $ref", "text/plain; charset=UTF-8", @notice);
}

# send all the notices
sub send_all_notices($$$)
{
    my ($ref, $old_sha1, $new_sha1) = @_;

    $ref =~ s/^refs\/heads\///;

    return if (grep { $_ =~ /^$ref/ } @exclude_list);

    if ($old_sha1 eq '0' x 40)  # new ref
    {
        send_commit_notice( $ref, $new_sha1 ) if $commitlist_address;
        return;
    }

    my @commits = ();

    open LIST, "-|" or exec "git", "rev-list", "^$old_sha1", "$new_sha1", (map { "^$_" } @exclude_list) or die "cannot exec git-rev-list";
    while (<LIST>)
    {
        chomp;
        die "invalid commit $_" unless /^[0-9a-f]{40}$/;
        unshift @commits, $_;
    }
    close LIST;

    if (@commits > $max_individual_notices)
    {
        send_global_notice( $ref, $old_sha1, $new_sha1 ) if $commitlist_address;
        return;
    }

    foreach my $commit (@commits)
    {
        send_commit_notice( $ref, $commit ) if $email_enabled && $commitlist_address;
        send_cia_notice( $ref, $commit ) if $cia_enabled && $cia_project_name;
    }
}

parse_options();

# append repository path to URL
$gitweb_url .= "?p=$repos_name";

if (@ARGV)
{
    send_all_notices( $ARGV[0], $ARGV[1], $ARGV[2] );
}
else  # read them from stdin
{
    while (<>)
    {
        chomp;
        if (/^([0-9a-f]{40}) ([0-9a-f]{40}) (.*)$/) { send_all_notices( $3, $1, $2 ); }
    }
}

exit 0;
