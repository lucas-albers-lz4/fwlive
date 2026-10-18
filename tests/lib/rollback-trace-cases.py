#!/usr/bin/env python3
"""Bounded input schedules for real-helper observations, never model actions."""
import argparse
import random

parser = argparse.ArgumentParser()
parser.add_argument('--seed', type=int, default=1322)
parser.add_argument('--generated', type=int, default=24)
args = parser.parse_args()
if not 0 <= args.generated <= 100:
    parser.error('generated sample count must be between 0 and 100')
values = [('enable', 'unset'), ('enable', '0'), ('disable', '1')]
scenarios = ['success', 'aba', 'noop', 'failed', 'failedstage', 'refusal',
             'reacquire', 'generation', 'stage', 'poststage', 'commit']
for intent, initial in values:
    for scenario in scenarios:
        print('|'.join([f'{intent}-{initial}-{scenario}', scenario, intent, initial, '-']))
rng = random.Random(args.seed)
for index in range(args.generated):
    intent, initial = rng.choice(values)
    attempts = [rng.choice(['enable', 'disable', 'fail-enable', 'fail-disable'])
                for _ in range(rng.randrange(3))]
    print('|'.join([f'seed-{args.seed}-{index}', 'scheduled', intent, initial,
                    ','.join(attempts) or '-']))
