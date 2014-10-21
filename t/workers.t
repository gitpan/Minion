use Mojo::Base -strict;

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test'
  unless $ENV{TEST_ONLINE};

use Mango::BSON 'bson_time';
use Minion;
use Sys::Hostname 'hostname';

# Clean up before start
my $minion = Minion->new($ENV{TEST_ONLINE});
is $minion->prefix, 'minion', 'right prefix';
my $workers = $minion->prefix('workers_test')->workers;
is $workers->name, 'workers_test.workers', 'right name';
my $jobs = $minion->jobs;
$_->options && $_->drop for $workers, $jobs;

# Nothing to repair
my $worker = $minion->repair->worker;
isa_ok $worker->minion->app, 'Mojolicious', 'has default application';

# Register and unregister
$worker->register;
like $worker->started, qr/^[\d.]+$/, 'has timestamp';
ok !$worker->unregister->minion->workers->find_one(
  {pid => $$, num => $worker->number}), 'not registered';
ok $worker->register->minion->workers->find_one(
  {host => hostname, pid => $$, num => $worker->number}), 'is registered';
ok !$worker->unregister->minion->workers->find_one(
  {host => hostname, pid => $$, num => $worker->number}), 'not registered';

# Repair dead worker
$minion->add_task(test => sub { });
my $worker2 = $minion->worker->register;
isnt $worker2->number, $worker->number, 'new number';
my $oid = $minion->enqueue('test');
my $job = $worker2->dequeue;
is $job->id, $oid, 'right object id';
my $num = $worker2->number;
undef $worker2;
is $job->state, 'active', 'job is still active';
my $doc = $workers->find_one({pid => $$, num => $num});
ok $doc, 'is registered';
my $pid = 4000;
$pid++ while kill 0, $pid;
$workers->save({%$doc, pid => $pid});
$minion->repair;
ok !$workers->find_one({pid => $$, num => $num}), 'not registered';
is $job->state, 'failed',            'job is no longer active';
is $job->error, 'Worker went away.', 'right error';

# Repair abandoned job
$worker->register;
$oid = $minion->enqueue('test');
$job = $worker->dequeue;
is $job->id, $oid, 'right object id';
$worker->unregister;
$minion->repair;
is $job->state, 'failed',            'job is no longer active';
is $job->error, 'Worker went away.', 'right error';
$_->drop for $workers, $jobs;

done_testing();
