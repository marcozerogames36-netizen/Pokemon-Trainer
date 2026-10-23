'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const GameRules = require('../assets/game-rules.js');

test('gym level cap is set by the leader’s strongest Pokémon', () => {
  assert.equal(GameRules.getGymLevelCap({ team: [{ level: 12 }, { level: 18 }, { level: 15 }] }), 18);
  assert.equal(GameRules.getGymLevelCap({ team: [] }), 0);
});

test('Pokémon at the cap are allowed and Pokémon above it are blocked', () => {
  assert.equal(GameRules.isPokemonWithinLevelCap({ level: 18 }, 18), true);
  assert.equal(GameRules.isPokemonWithinLevelCap({ level: 19 }, 18), false);
  assert.equal(GameRules.isPokemonWithinLevelCap({ level: undefined }, 18), false);
});

test('Recover without saved API metadata remains a self-healing move', () => {
  const recover = { name: 'Recover', power: 0 };
  assert.equal(GameRules.getSelfHealingPercent(recover), 50);
  assert.equal(GameRules.isSelfHealingMove(recover), true);
});

test('healing moves restore the configured percentage without exceeding max HP', () => {
  assert.equal(GameRules.getSelfHealingAmount(20, 100, 50), 50);
  assert.equal(GameRules.getSelfHealingAmount(80, 100, 50), 20);
  assert.equal(GameRules.getSelfHealingAmount(100, 100, 50), 0);
});

test('Brock, Lt. Surge, Erika, and Giovanni enforce their progression requirements', () => {
  assert.equal(GameRules.getGymProgressionBlockReason({ gymIndex: 0, explorationComplete: false }), 'brock_exploration');
  assert.equal(GameRules.getGymProgressionBlockReason({ gymIndex: 0, explorationComplete: true }), '');
  assert.equal(GameRules.getGymProgressionBlockReason({ gymIndex: 2, badgeCount: 2, ssAnneWins: 4 }), 'lt_surge_ss_anne');
  assert.equal(GameRules.getGymProgressionBlockReason({ gymIndex: 2, badgeCount: 2, ssAnneWins: 5 }), '');
  assert.equal(GameRules.getGymProgressionBlockReason({ gymIndex: 3, badgeCount: 3, lavenderComplete: false }), 'erika_tower');
  assert.equal(GameRules.getGymProgressionBlockReason({ gymIndex: 3, badgeCount: 3, lavenderComplete: true }), '');
  assert.equal(GameRules.getGymProgressionBlockReason({ gymIndex: 7, badgeCount: 7, silphWins: 2 }), 'giovanni_silph');
  assert.equal(GameRules.getGymProgressionBlockReason({ gymIndex: 7, badgeCount: 7, silphWins: 3 }), '');
});

test('administrative test access and already-earned badges bypass gym progression checks', () => {
  assert.equal(GameRules.getGymProgressionBlockReason({ gymIndex: 0, isAdmin: true }), '');
  assert.equal(GameRules.getGymProgressionBlockReason({ gymIndex: 7, alreadyHasBadge: true }), '');
});

test('S.S. Anne needs both the Cascade Badge and Bill’s ticket for regular accounts', () => {
  assert.equal(GameRules.canAccessSSAnne({ hasCascadeBadge: true, ticketCount: 1 }), true);
  assert.equal(GameRules.canAccessSSAnne({ hasCascadeBadge: false, ticketCount: 1 }), false);
  assert.equal(GameRules.canAccessSSAnne({ hasCascadeBadge: true, ticketCount: 0 }), false);
  assert.equal(GameRules.canAccessSSAnne({ isAdmin: true }), true);
});

test('Silph Co. stays locked until Sabrina is defeated, except for admin testing', () => {
  assert.equal(GameRules.canAccessSilphCo(false, false), false);
  assert.equal(GameRules.canAccessSilphCo(false, true), true);
  assert.equal(GameRules.canAccessSilphCo(true, false), true);
});
