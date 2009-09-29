#!/usr/bin/env perl -w

use strict;
use warnings;

use Test::More;
use DBIx::Connection;

my ($table_sql, $dsn, $user, $pass);

if (exists $ENV{DBICTEST_PG_DSN}) {
    ($dsn, $user, $pass) = @ENV{map { "DBICTEST_PG_${_}" } qw/DSN USER PASS/};
    $table_sql = q{
        SET client_min_messages = warning;
        DROP TABLE IF EXISTS artist;
        CREATE TABLE artist (id serial PRIMARY KEY, name TEXT);
    };
# } elsif (exists $ENV{DBICTEST_MYSQL_DSN}) {
#     ($dsn, $user, $pass) = @ENV{map { "DBICTEST_MYSQL_${_}" } qw/DSN USER PASS/};
#     $table_sql = q{
#         DROP TABLE IF EXISTS artist;
#         CREATE TABLE artist (
#             id INTEGER NOT NULL AUTO_INCREMENT PRIMARY KEY, name TEXT
#         ) ENGINE=InnoDB;
#     };
} else {
    plan skip_all => 'Set DBICTEST_(PG|MYSQL)_DSN _USER and _PASS if you want to run savepoint tests';
}

plan tests => 34;

ok my $conn = DBIx::Connection->new($dsn, $user, $pass, {
    PrintError => 0,
    RaiseError => 1,
}), 'Get a connection';
ok my $dbh = $conn->dbh, 'Get the database handle';
isa_ok $dbh, 'DBI::db', 'The handle';

ok $dbh->do(qq{
    $table_sql;
    INSERT INTO artist (name) VALUES('foo')
}), 'Create the test table';

END {
    return unless $dbh;
    $dbh->do('DROP TABLE artist');
    $dbh->disconnect;
}

my $sel = $dbh->prepare('SELECT name FROM artist WHERE id = 1');
my $upd = $dbh->prepare('UPDATE artist SET name = ? WHERE id = 1');

ok $dbh->begin_work, 'Start a transaction';
is $dbh->selectrow_array($sel), 'foo', 'Name should be "foo"';

# First off, test a generated savepoint name
ok $conn->savepoint, 'Savepoint';
ok $upd->execute('Jheephizzy'), 'Update to "Jheephizzy"';
is $dbh->selectrow_array($sel), 'Jheephizzy', 'The name should now be "Jheephizzy"';

# Rollback the generated name
# Active: 0
ok $conn->rollback_to, 'Rollback the savepoint';
is $dbh->selectrow_array($sel), 'foo', 'Name should be "foo" again';

ok $upd->execute('Jheephizzy'), 'Update to "Jheephizzy" again';

# Active: 0
ok $conn->savepoint('testing1'), 'Savepoint testing1';
ok $upd->execute('yourmom'), 'Update to "yourmom"';

# Active: 0 1
ok $conn->savepoint('testing2'), 'Savepont testing2';
ok $upd->execute('gphat'), 'Update to "gphat"';
is $dbh->selectrow_array($sel), 'gphat', 'Name should be "gphat"';

# Active: 0 1
# Rollback doesn't DESTROY the savepoint, it just rolls back to the value
# at it's conception
ok $conn->rollback_to('testing2'), 'Rollback testing2';
is $dbh->selectrow_array($sel), 'yourmom', 'Name should be "yourmom"';

# Active: 0 1 2
ok $conn->savepoint('testing3'), 'Savepoint testing3';
ok $upd->execute('coryg'), 'Update to "coryg"';
# Active: 0 1 2 3
ok $conn->savepoint('testing4'), 'Savepoint testing4';
ok $upd->execute('watson'), 'Update to "watson"';

# Release 3, which implicitly releases 4
# Active: 0 1
ok $conn->release('testing3'), 'Release testing3';
is $dbh->selectrow_array($sel), 'watson', 'Name should be "watson"';

# This rolls back savepoint 2
# Active: 0 1
ok $conn->rollback_to, 'Rollback to [savepoint2]';
is $dbh->selectrow_array($sel), 'yourmom', 'Name should be "yourmom" again';

# Rollback the original savepoint, taking us back to the beginning, implicitly
# rolling back savepoint 1
ok $conn->rollback_to('savepoint_0'), 'Rollback to the beginning';
is $dbh->selectrow_array($sel), 'foo', 'Name should be "foo" once more';

ok $dbh->commit, 'Commit the changes';

# And now to see if svp_do will behave correctly
$conn->svp_do (sub {
    $conn->txn_do (sub { $upd->execute('Muff') });

    eval {
        $conn->svp_do(sub {
            $upd->execute('Moff');
            is $dbh->selectrow_array($sel), 'Moff', 'Name should be "Moff" in nested transaction';
            shift->do('SELECT 1/0');
        });
    };
    ok $@,'Nested transaction failed (good)';
    is $dbh->selectrow_array($sel), 'Muff', 'Rolled back name should be "Muff"';
    $upd->execute('Miff');
});

is $dbh->selectrow_array($sel), 'Miff', 'Savepoint worked: name is "Muff"';
