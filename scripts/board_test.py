"""Behavior tests: all facts are local values; no network, Kanzo or T3."""
import copy
import fcntl
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import tempfile
import json

# -I omits the script directory; import only the sibling modules explicitly.
sys.path.insert(0, str(Path(__file__).resolve().parent))
spec = importlib.util.spec_from_file_location('board', Path(__file__).with_name('sid-board.py'))
board = importlib.util.module_from_spec(spec)
spec.loader.exec_module(board)
spec = importlib.util.spec_from_file_location('sid_card', Path(__file__).with_name('sid-card.py'))
sid_card = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sid_card)
NOW = 2000000000


def card(**kw):
    return dict(dict(key='chat#29', title='Work', status='todo', tags=[], comments=[], repo='/repo'), **kw)


def pr(**kw):
    return dict(dict(number=8, state='OPEN', title='Kanzo chat#29', body='', headRefName='feature',
                     headRefOid='head', updatedAt='2030-01-01T00:00:00+00:00'), **kw)


def thread(**kw):
    return dict(dict(id='child', root='root', parent='root', title='Sol chat#29', run='running',
                     model='gpt-6.1-sol', provider='codex', effort='high', activity=NOW-2000, prs=[]), **kw)


def facts(c=None, p=None, ts=None):
    return dict(cards=[c or card()], projects=['chat', 'process'],
                repos={'/repo': dict(name='owner/repo', prs=[p or pr()], train_ok=True)},
                threads=[thread()] if ts is None else ts)


def result(f, state=None, now=NOW):
    return board.reconcile(f, state or {}, now)


def apply(f, actions):
    f = copy.deepcopy(f)
    for a in actions:
        if a['kind'] == 'update':
            c = next(c for c in f['cards'] if c['key'] == a['key'])
            for k, v in a['fields'].items():
                c[k] = v.split(', ') if k == 'tags' and v else ([] if k == 'tags' else v)
    return f


class BoardTests(unittest.TestCase):
    def test_worker_and_reviewer(self):
        for ts, status in [(thread(), 'doing'), (thread(model='gpt-6-astra'), 'review'),
                           (thread(model='composer'), 'review'), (thread(title='Verify chat#29'), 'review'),
                           (thread(model='gpt-6.1-terra'), 'todo')]:
            with self.subTest(ts=ts):
                a, s, rows, _ = result(facts(ts=[ts]))
                c = apply(facts(ts=[ts]), a)['cards'][0]
                self.assertEqual(c['status'], status)
                self.assertTrue({'codex', ts['model'], 'high'} <= set(c['tags']))
                self.assertEqual(rows[0]['owner'], 'root')

    def test_no_worker_moves_backwards(self):
        for status in ('review', 'deployment'):
            a, *_ = result(facts(card(status=status)))
            self.assertEqual(apply(facts(card(status=status)), a)['cards'][0]['status'], status)

    def test_pr_token_and_tags(self):
        f = facts(p=pr(title='chat#299'), ts=[])
        self.assertEqual(result(f)[2][0]['pr'], '-')
        for text in ('Kanzo chat#29.', '(chat#29)', 'chat#29', 'chat#29-fix'):
            f['repos']['/repo']['prs'] = [pr(title=text)]
            self.assertEqual(result(f)[2][0]['pr'], 8)
        f['cards'][0]['tags'] = ['pr-8']
        f['repos']['/repo']['prs'] = [pr(title='unrelated')]
        self.assertEqual(result(f)[2][0]['pr'], 8)

    def test_body_ownership_requires_kanzo_declaration(self):
        for body, owns in [('bell parity split to chat#29', False),
                           ('(chat#29 adds one)', False), ('Kanzo chat#299', False),
                           ('NotKanzo chat#29', False), ('Kanzo: chat#29', False),
                           ('Kanzo chat#29.', True), ('(Kanzo chat#29)', True),
                           ('Kanzo chat#27, chat#28 and chat#29.', True),
                           ('Kanzo chat#27 and chat#28; follow-up chat#29', False)]:
            with self.subTest(body=body):
                f = facts(p=pr(title='Other', body=body), ts=[])
                self.assertEqual(result(f)[2][0]['pr'], 8 if owns else '-')
        self.assertEqual(result(facts(p=pr(title='Other', headRefName='fix/chat#29')))[2][0]['pr'], 8)

    def test_idle_without_pr_and_closed_pr(self):
        for status in ('doing', 'review', 'deployment', 'todo'):
            for ps in ([], [pr(state='CLOSED')], [pr()], [pr(phase='queued')]):
                with self.subTest(status=status, prs=ps):
                    f = facts(card(status=status), ts=[thread(run='completed'),
                        thread(id='root', parent=None, title='owner', run='completed')])
                    f['repos']['/repo']['prs'] = ps
                    a, state, *_ = result(f)
                    f = apply(f, a)
                    a, state, *_ = result(f, state)
                    f = apply(f, a)
                    self.assertFalse(result(f, state, NOW+1199)[2][0]['now'].startswith('idle '))
                    a, _, rows, stalled = result(f, state, NOW+1200)
                    expected = not any(p.get('phase') for p in ps) and (
                        status in ('doing', 'review') or status == 'deployment' and bool(ps))
                    self.assertEqual(rows[0]['now'].startswith('idle '), expected)
                    if expected and not ps:
                        self.assertIn('no PR', stalled[0]['reason'])
                    f['threads'][0]['run'] = 'running'
                    self.assertFalse(result(f, state, NOW+1201)[2][0]['now'].startswith('idle '))

    def test_stale_removed_from_all_handled_cards(self):
        for status in ('todo', 'doing', 'review', 'deployment'):
            f = facts(card(status=status, tags=['stale', 'keep']), ts=[])
            f['repos']['/repo']['prs'] = []
            self.assertEqual(set(apply(f, result(f)[0])['cards'][0]['tags']) - {'<1m'}, {'keep'})

    def github_command(self, calls, common):
        def command(*args, **kw):
            calls.append(args)
            if args[:3] == ('gh', 'repo', 'view'):
                return json.dumps(dict(nameWithOwner='owner/repo', defaultBranchRef={'name': 'main'}))
            if args[:3] == ('gh', 'pr', 'list'):
                return json.dumps([pr(number=100, title='other')])
            if args[:3] == ('gh', 'pr', 'view'):
                return json.dumps(pr(number=int(args[3]), title='Other', state='MERGED',
                                     mergeCommit={'oid': 'abc'}))
            if args[:2] == ('gh', 'api'):
                if args[2].endswith('/statuses'):
                    return '[{"state":"success"}]'
                return '[{"id":1,"sha":"live","environment":"OpenEcommerce / production"}]'
            if args[:2] == ('git', 'rev-parse'):
                return str(common)
            if args[:2] == ('git', 'ls-remote'):
                return 'mainsha refs/heads/main'
            return ''
        return command

    def test_missing_tagged_pr_is_fetched_and_lookup_is_bounded(self):
        with tempfile.TemporaryDirectory() as tmp:
            calls = []
            with patch.object(board, 'command', side_effect=self.github_command(calls, Path(tmp))), \
                    patch.object(board.subprocess, 'run') as ancestry:
                ancestry.return_value.returncode = 0
                info = dict(nameWithOwner='owner/repo', defaultBranchRef={'name': 'main'})
                cards = [card(status='review', tags=[f'pr-{n}']) for n in range(1, 26)]
                cards += [card(status='done', tags=['pr-99']), card(tags=['pr-98'])]
                repo = board.gather_github('/repo', info, cards)
            lookups = [c for c in calls if c[:3] == ('gh', 'pr', 'view')]
            self.assertEqual([int(c[3]) for c in lookups], list(range(1, 21)))
            f = facts(card(status='review', tags=['pr-1']), ts=[])
            f['repos']['/repo'] = dict(repo, train_ok=True)
            self.assertEqual(result(f)[2][0]['column'], 'done')

    def test_github_cache_cadence_expiry_and_local_train(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            calls = []
            with patch.object(board.kanzo, 'STATE', directory / 'cards.json'), \
                    patch.object(board, 'command', side_effect=self.github_command(calls, directory)), \
                    patch.object(board.time, 'time', return_value=NOW) as clock:
                first = board.gather_repo('/repo')
                self.assertTrue(any(c[:3] == ('gh', 'repo', 'view') for c in calls))
                calls.clear()
                queue = directory / 'sid-gate/train/queue/100.req'
                queue.parent.mkdir(parents=True)
                queue.touch()
                clock.return_value = NOW+20
                self.assertEqual(board.gather_repo('/repo')['prs'][0]['phase'], 'queued')
                self.assertFalse(any(c[0] == 'gh' for c in calls))
                queue.unlink()
                clock.return_value = NOW+59
                self.assertNotIn('phase', board.gather_repo('/repo')['prs'][0])
                clock.return_value = NOW+60
                board.gather_repo('/repo')
                self.assertTrue(any(c[:3] == ('gh', 'pr', 'list') for c in calls))
                self.assertFalse(any(c[:3] == ('gh', 'repo', 'view') for c in calls))
                with patch.object(board, 'gather_github', side_effect=RuntimeError('offline')) as refresh:
                    clock.return_value = NOW+120
                    self.assertIsNotNone(board.gather_repo('/repo')['prs'])
                    clock.return_value = NOW+140
                    board.gather_repo('/repo')
                    self.assertEqual(refresh.call_count, 1)
                    clock.return_value = NOW+661
                    self.assertIsNone(board.gather_repo('/repo')['prs'])
                self.assertFalse((directory / 'cards.json').exists())

    def test_status_and_dry_run_leave_board_and_state_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            config = directory / 'config.json'
            config.write_text('[]')
            state = directory / 'cards.json'
            state.write_text('{"sentinel":true}')
            with patch.object(board.kanzo, 'STATE', state), \
                    patch.object(board, 'gather', return_value=facts()), \
                    patch.object(board.kanzo, 'lock', return_value=True), \
                    patch.object(board, 'apply') as mutate, \
                    patch.object(board.kanzo, 'save') as save, \
                    patch('builtins.print'):
                for args in (['sync', '--dry-run'], ['status']):
                    with patch.object(sys, 'argv', ['sid-board', *args, '--config', str(config)]):
                        board.main()
                mutate.assert_not_called()
                save.assert_not_called()
                self.assertEqual(state.read_text(), '{"sentinel":true}')

    def test_pr_selection(self):
        f = facts(ts=[])
        f['repos']['/repo']['prs'] = [pr(number=1, state='MERGED'), pr(number=2, phase='queued'), pr(number=3)]
        self.assertEqual(result(f)[2][0]['pr'], 3)
        f['repos']['/repo']['prs'] = [pr(number=1, state='CLOSED', updatedAt='a'), pr(number=2, state='CLOSED', updatedAt='b')]
        self.assertEqual(result(f)[2][0]['pr'], 2)

    def test_multiple_explicit_pr_links_survive_until_live(self):
        f = facts(card(tags=['pr-8', 'pr-9']), ts=[])
        f['repos']['/repo']['prs'] = [pr(title='other'), pr(number=9, title='other', phase='queued')]
        a, s, rows, _ = result(f)
        f = apply(f, a)
        self.assertEqual(rows[0]['pr'], 8)
        self.assertTrue({'pr-8', 'pr-9'} <= set(f['cards'][0]['tags']))
        f['repos']['/repo']['prs'][0]['state'] = 'CLOSED'
        self.assertEqual(result(f, s)[2][0]['pr'], 9)

    def test_train(self):
        for phase in ('queued', 'gating', 'merging'):
            f = facts(p=pr(phase=phase))
            a, _, rows, _ = result(f)
            c = apply(f, a)['cards'][0]
            self.assertEqual(c['status'], 'deployment')
            self.assertIn(phase, c['tags'])
            self.assertEqual(rows[0]['now'], phase)

    def test_merged_and_live(self):
        f = facts(p=pr(state='MERGED', mergeCommit={'oid': 'abcdef012345'}, trailer='Gate-Passed: abc lane'), ts=[])
        a, s, rows, _ = result(f)
        self.assertEqual(rows[0]['column'], 'deployment')
        self.assertIn('deploying', apply(f, a)['cards'][0]['tags'])
        comments = [x['body'] for x in a if x['kind'] == 'comment']
        self.assertEqual(comments, ['Merged #8 as abcdef01.\nGate-Passed: abc lane'])
        f = apply(f, a)
        self.assertFalse(any(x['kind'] == 'comment' for x in result(f, s)[0]))
        f['repos']['/repo']['prs'][0]['live'] = 'live012345'
        a, s, rows, _ = result(f, s)
        self.assertEqual(rows[0]['column'], 'done')
        self.assertEqual(apply(f, a)['cards'][0]['tags'], ['pr-8'])
        self.assertTrue(any('deploy live0123' in x.get('body', '') for x in a))
        f['repos']['/repo']['no_deploy'] = True
        a, *_ = result(f)
        self.assertTrue(any('no deploy step' in x.get('body', '') for x in a))

    def test_closed_worker_does_not_move_card(self):
        f = facts(p=pr(state='CLOSED'), ts=[thread(model='gpt-6-astra')])
        self.assertEqual(result(f)[2][0]['column'], 'todo')

    def test_closed(self):
        f = facts(card(status='review'), pr(state='CLOSED'), [])
        a, s, rows, _ = result(f)
        self.assertEqual(rows[0]['column'], 'review')
        self.assertIn('scrapped', apply(f, a)['cards'][0]['tags'])
        self.assertEqual(len([x for x in a if x['kind'] == 'comment']), 1)
        self.assertEqual(result(apply(f, a), s)[0], [])

    def test_pending_and_owner_from_pr(self):
        t = thread(id='root', parent=None, run='completed', pending=True, prs=[['owner/repo', 8]])
        f = facts(ts=[t])
        a, s, rows, stalled = result(f)
        self.assertEqual(rows[0]['owner'], 'root')
        self.assertIn('needs-you', apply(f, a)['cards'][0]['tags'])
        f = apply(f, a)
        f['threads'][0]['pending'] = False
        a, *_ = result(f, s)
        self.assertNotIn('needs-you', apply(f, a)['cards'][0]['tags'])

    def idle(self):
        f = facts(card(status='review'), ts=[thread(id='root', parent=None, run='completed', prs=[['owner/repo', 8]])])
        a, s, *_ = result(f)
        f = apply(f, a)
        # Establish stable board and worker facts, then wait twenty minutes.
        a, s, *_ = result(f, s)
        f = apply(f, a)
        return f, s

    def test_idle_stalled_and_elapsed(self):
        f, s = self.idle()
        a, s, rows, stalled = result(f, s, NOW+1201)
        self.assertEqual(len(stalled), 1)
        self.assertTrue(rows[0]['now'].startswith('idle '))
        self.assertIn('20m', apply(f, a)['cards'][0]['tags'])
        f['threads'].append(thread())
        a, _, rows, stalled = result(f, s, NOW+1202)
        self.assertFalse(stalled)
        self.assertFalse(rows[0]['now'].startswith('idle '))

    def test_nudge_signature_survives_a_run_without_progress(self):
        f, state = self.idle()
        _, state, _, stalled = result(f, state, NOW+1201)
        original = stalled[0]['signature']
        f['threads'][0]['activity'] = NOW+1202
        _, state, _, _ = result(f, state, NOW+1203)
        _, state, _, stalled = result(f, state, NOW+2500)
        self.assertEqual(stalled[0]['signature'], original)

    def test_nudge_limits_and_spacing(self):
        item = dict(thread='root', reason='unfinished', cards=['chat#29'], signature='same', activity=NOW-1000)
        self.assertEqual(board.nudges([dict(item, activity=NOW-899)], {}, NOW)[0], [])
        a, s = board.nudges([item], {}, NOW)
        self.assertEqual([x['kind'] for x in a], ['nudge'])
        self.assertEqual(board.nudges([item], s, NOW+1799)[0], [])
        a, s = board.nudges([item], s, NOW+1800)
        self.assertEqual(len(a), 1)
        self.assertEqual(board.nudges([item], s, NOW+5399)[0], [])
        a, s = board.nudges([item], s, NOW+5400)
        self.assertEqual([x['kind'] for x in a], ['nudge', 'stuck'])
        self.assertEqual(board.nudges([item], s, NOW+99999)[0], [])
        self.assertEqual(board.nudges([item], {}, NOW, True)[0], [])
        item['signature'] = 'changed'
        self.assertEqual(len(board.nudges([item], s, NOW+99999)[0]), 1)

    def test_nudge_exclusions(self):
        for change in ({'run': 'cancelled'}, {'pending': True}, {'run': 'running'}, {'activity': NOW+1000}):
            f, s = self.idle()
            f['threads'][0].update(change)
            self.assertEqual(result(f, s, NOW+1201)[3], [])
        f, s = self.idle()
        f['threads'].append(thread(title='unrelated child'))
        self.assertEqual(result(f, s, NOW+1201)[3], [])

    def test_train_result_stalled(self):
        f = facts(p=pr(state='MERGED', mergedAt=board.stamp(NOW-100)), ts=[thread(id='root', parent=None, run='failed', prs=[['owner/repo', 8]])])
        self.assertEqual(len(result(f)[3]), 1)
        f['repos']['/repo']['prs'] = [pr(failed_at=NOW-100)]
        self.assertEqual(len(result(f)[3]), 1)

    def test_main_health(self):
        f = facts(ts=[])
        f['repos']['/repo']['health'] = dict(sha='bad', result='fail', lane='checks')
        a, s, *_ = result(f)
        self.assertEqual(len([x for x in a if x['kind'] == 'create']), 1)
        f['cards'].append(card(key='process#99', title='Main is red: repo', status='todo'))
        a, s, *_ = result(f, s)
        self.assertFalse(any(x['kind'] in ('create', 'comment') for x in a))
        f['repos']['/repo']['health']['sha'] = 'bad2'
        a, s, *_ = result(f, s)
        self.assertTrue(any('bad2' in x.get('body', '') for x in a))
        f['repos']['/repo']['health'].update(sha='good', result='pass')
        a, *_ = result(f, s)
        self.assertEqual(apply(f, a)['cards'][1]['status'], 'done')

    def test_excluded_cards(self):
        for c in (card(human=True), card(status='done'), card(status='backlog')):
            self.assertEqual(result(facts(c))[0], [])

    def test_repeat_has_no_actions_and_no_input_mutation(self):
        f = facts()
        before = copy.deepcopy(f)
        a, s, *_ = result(f)
        self.assertEqual(f, before)
        self.assertEqual(result(apply(f, a), s)[0], [])

    def test_missing_sources(self):
        f = facts(card(status='review', tags=['gating', 'codex', 'needs-you']))
        f['threads'] = None
        f['repos']['/repo'] = dict(prs=None, train_ok=False)
        a, s, rows, stalled = result(f)
        c = apply(f, a)['cards'][0]
        self.assertEqual(c['status'], 'review')
        self.assertTrue({'gating', 'codex', 'needs-you'} <= set(c['tags']))
        self.assertFalse(stalled)

    def test_new_comment_and_time_in_column(self):
        f = facts(card(status='review', comments=[dict(id=1, author='me', body='continue')]), ts=[])
        a, s, *_ = result(f)
        f = apply(f, a)
        self.assertIn('new-comment', f['cards'][0]['tags'])
        a, s, *_ = result(f, s, NOW+60)
        self.assertIn('1m', apply(f, a)['cards'][0]['tags'])
        self.assertNotIn('stale', apply(f, a)['cards'][0]['tags'])

    def test_legacy_state_missing_changed(self):
        f, state = self.idle()
        state['chat#29'] = {'fingerprint': state['chat#29']['fingerprint']}
        _, state, _, _ = result(f, state, NOW + 5000)
        _, _, rows, _ = result(f, state, NOW + 8000)
        self.assertTrue(rows[0]['now'].startswith('idle '))

    def test_stuck_keeps_tags_from_earlier_update(self):
        captured = []
        working = copy.deepcopy(facts(card(tags=['before']), ts=[]))
        planned = [
            {'kind': 'update', 'key': 'chat#29', 'fields': {'tags': 'before, pr-8, deploying'}},
            {'kind': 'stuck', 'key': 'chat#29', 'thread': 'root'},
        ]
        with patch.object(board.kanzo, 'connect'), patch.object(board.kanzo, 'human'), \
                patch.object(board.kanzo, 'update', side_effect=lambda _k, **kw: captured.append(kw.get('tags', ''))):
            board.apply_actions(planned, working, {'_nudges': {'root': {'count': 3}}}, {},
                                [{'thread': 'root'}], save=lambda _: None)
        self.assertIn('pr-8', captured[-1])
        self.assertIn('stuck', captured[-1])

    def test_only_production_deployments_are_live(self):
        info = dict(nameWithOwner='owner/repo', defaultBranchRef={'name': 'main'})
        for environments, expected in [([], 'done'), (['preview'], 'deployment'),
                (['OpenEcommerce / PrOdUcTiOn'], 'done'),
                (['preview', 'production'], 'done'), ([''], 'deployment')]:
            with self.subTest(environments=environments):
                calls = []
                base = self.github_command(calls, Path('/unused'))
                def command(*args, **kw):
                    if args[:3] == ('gh', 'pr', 'list'):
                        return json.dumps([pr(state='MERGED', mergeCommit={'oid': 'merged'})])
                    if args[:2] == ('gh', 'api') and not args[2].endswith('/statuses'):
                        return json.dumps([dict(id=i, sha=f'live{i}', environment=env)
                                           for i, env in enumerate(environments)])
                    return base(*args, **kw)
                with patch.object(board, 'command', side_effect=command), \
                        patch.object(board.subprocess, 'run') as ancestry:
                    ancestry.return_value.returncode = 0
                    repo = board.gather_github('/repo', info, [])
                f = facts(ts=[])
                f['repos']['/repo'] = dict(repo, train_ok=True)
                actions, _, rows, _ = result(f)
                self.assertEqual(rows[0]['column'], expected)
                live_comments = [a for a in actions if 'Live on prod' in a.get('body', '')]
                self.assertEqual(bool(live_comments), bool(environments) and expected == 'done')
                if environments == ['preview', 'production']:
                    self.assertEqual(repo['prs'][0]['live'], 'live1')

    def test_comments_precede_done_and_failure_blocks_move(self):
        for failure in (None, 'Merged', 'Live on prod'):
            with self.subTest(failure=failure):
                f = facts(p=pr(state='MERGED', mergeCommit={'oid': 'abc'}, live='live'), ts=[])
                actions, state, _, stalled = result(f)
                calls = []
                def transport(batch, _facts):
                    action = batch[0]
                    calls.append(action)
                    if failure and action['kind'] == 'comment' and action['body'].startswith(failure):
                        raise RuntimeError('comment unavailable')
                if failure:
                    with self.assertRaises(SystemExit):
                        board.apply_actions(actions, f, {}, state, stalled, transport, lambda _: None)
                    self.assertFalse(any(a['kind'] == 'update' and 'status' in a['fields'] for a in calls))
                    self.assertTrue(state['_outbox'])
                else:
                    board.apply_actions(actions, f, {}, state, stalled, transport, lambda _: None)
                    self.assertEqual([a['kind'] for a in calls], ['comment', 'comment', 'update'])
                    self.assertEqual(f['cards'][0]['status'], 'done')

    def test_replayed_stuck_is_dropped_when_no_longer_eligible(self):
        action = dict(kind='stuck', key='chat#29', thread='root')
        for change, stalled in [({'human': True}, [{'thread': 'root'}]),
                ({'status': 'done'}, [{'thread': 'root'}]),
                ({'status': 'backlog'}, [{'thread': 'root'}]), ({}, []),
                ({}, [{'thread': 'root'}])]:
            with self.subTest(change=change, stalled=stalled):
                previous = {'_outbox': [action], '_nudges': {'root': {'count': 3}}}
                state = copy.deepcopy(previous)
                sent = []
                board.apply_actions([], facts(card(**change)), previous, state, stalled,
                                    lambda batch, _: sent.extend(batch), lambda _: None)
                self.assertEqual(sent, [action] if not change and stalled else [])
                self.assertEqual(state['_outbox'], [])

    def test_main_health_respects_backlog_and_human_but_reopens_done(self):
        for health in ('fail', 'pass'):
            for status, human in [('backlog', False), ('done', True), ('done', False)]:
                with self.subTest(health=health, status=status, human=human):
                    f = facts(card(key='process#99', title='Main is red: repo', status=status, human=human), ts=[])
                    f['repos']['/repo']['health'] = dict(sha='bad', result=health, lane='checks')
                    actions, *_ = result(f)
                    if status == 'backlog' or human or health == 'pass':
                        self.assertEqual(actions, [])
                    else:
                        self.assertEqual(apply(f, actions)['cards'][0]['status'], 'todo')

    def test_train_read_failure_does_not_publish_partial_facts(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            queue = directory / 'sid-gate/train/queue/8.req'
            queue.parent.mkdir(parents=True)
            queue.touch()
            health = directory / 'sid-gate/health/head'
            health.parent.mkdir(parents=True)
            health.write_text('fail checks')
            bad_health = health.with_name('unreadable')
            bad_health.mkdir()  # A later PR's read fails after the first PR's facts were read.
            cached = dict(name='owner/repo', prs=[pr(), pr(number=9, headRefOid='unreadable')])
            cache = directory / ('github-' + board.digest('/repo')[:20] + '.json')
            cache.write_text(json.dumps(dict(attempted=NOW, fetched=NOW, facts=cached)))
            with patch.object(board.kanzo, 'STATE', directory / 'cards.json'), \
                    patch.object(board.time, 'time', return_value=NOW), \
                    patch.object(board, 'command', return_value=str(directory)):
                repo = board.gather_repo('/repo')
                self.assertFalse(repo['train_ok'])
                self.assertFalse(any('phase' in p or 'failed_at' in p for p in repo['prs']))
                bad_health.rmdir()
                repo = board.gather_repo('/repo')
                self.assertTrue(repo['train_ok'])
                self.assertEqual(repo['prs'][0]['phase'], 'queued')
                self.assertIn('failed_at', repo['prs'][0])

    def test_explicit_card_commands_wait_and_report_busy(self):
        for command in ('work', 'clear', 'shots', 'inbox', 'tick'):
            with self.subTest(command=command), \
                    patch.object(sys, 'argv', ['sid-card', command]), \
                    patch.object(sid_card, 'lock', return_value=None) as lock, \
                    patch.object(sid_card, 'connect') as connect:
                if command == 'tick':
                    sid_card.main()
                else:
                    with self.assertRaises(SystemExit) as error:
                        sid_card.main()
                    self.assertTrue(error.exception.code)
                    self.assertIn('board was busy', str(error.exception))
                lock.assert_called_once_with(timeout=0 if command == 'tick' else 60)
                connect.assert_not_called()

    def test_lock_waits_for_release_and_times_out(self):
        with tempfile.TemporaryDirectory() as tmp, \
                patch.object(board.kanzo, 'STATE', Path(tmp) / 'cards.json'):
            held = board.kanzo.lock()
            self.assertIsNotNone(held)
            try:
                self.assertIsNone(board.kanzo.lock())
                with patch('time.monotonic', side_effect=[0, 0, 60]), \
                        patch('time.sleep') as sleep:
                    self.assertIsNone(board.kanzo.lock(timeout=60))
                    self.assertTrue(sleep.called)
                def release(_):
                    fcntl.flock(held, fcntl.LOCK_UN)
                with patch('time.sleep', side_effect=release):
                    acquired = board.kanzo.lock(timeout=60)
                self.assertIsNotNone(acquired)
                acquired.close()
            finally:
                held.close()


if __name__ == '__main__':
    unittest.main()
