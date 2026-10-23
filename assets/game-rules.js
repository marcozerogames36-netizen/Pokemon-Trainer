(function (root) {
  'use strict';

  function getGymLevelCap(gym) {
    const levels = Array.isArray(gym?.team)
      ? gym.team.map((pokemon) => Number(pokemon?.level) || 0)
      : [];
    return Math.max(0, ...levels);
  }

  function isPokemonWithinLevelCap(pokemon, levelCap) {
    const level = Number(pokemon?.level);
    const cap = Number(levelCap);
    return Number.isFinite(level) && Number.isFinite(cap) && level <= cap;
  }

  function getSelfHealingPercent(move, canonicalName = move?.name) {
    const name = String(canonicalName || '')
      .normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '')
      .toLowerCase()
      .replace(/[^a-z0-9]/g, '');

    // Older saved Recover records may not contain API healing metadata.
    if (name === 'recover') return 50;

    const healing = Number(move?.healing);
    return Number.isFinite(healing) ? Math.max(0, Math.min(100, healing)) : 0;
  }

  function isSelfHealingMove(move, canonicalName = move?.name) {
    const power = Number(move?.power);
    return (!Number.isFinite(power) || power <= 0) &&
      getSelfHealingPercent(move, canonicalName) > 0;
  }

  function getSelfHealingAmount(currentHp, maxHp, healingPercent) {
    const maximum = Math.max(1, Number(maxHp) || 1);
    const current = Math.max(0, Math.min(maximum, Number(currentHp) || 0));
    const percent = Math.max(0, Math.min(100, Number(healingPercent) || 0));
    if (percent <= 0 || current >= maximum) return 0;
    return Math.min(maximum - current, Math.max(1, Math.ceil(maximum * percent / 100)));
  }

  function getGymProgressionBlockReason(state) {
    if (state?.isAdmin || state?.alreadyHasBadge) return '';
    const gymIndex = Number(state?.gymIndex);
    if (gymIndex > 0 && (Number(state?.badgeCount) || 0) < gymIndex) return 'previous_badge';
    if (gymIndex === 0 && !state?.explorationComplete) return 'brock_exploration';
    if (gymIndex === 2 && (Number(state?.ssAnneWins) || 0) < 5) return 'lt_surge_ss_anne';
    if (gymIndex === 3 && !state?.lavenderComplete) return 'erika_tower';
    if (gymIndex === 7 && (Number(state?.silphWins) || 0) < 3) return 'giovanni_silph';
    return '';
  }

  function canAccessSSAnne(state) {
    return Boolean(state?.isAdmin || (state?.hasCascadeBadge && Number(state?.ticketCount) >= 1));
  }

  function canAccessSilphCo(isAdmin, sabrinaDefeated) {
    return Boolean(isAdmin || sabrinaDefeated);
  }

  const rules = Object.freeze({
    getGymLevelCap,
    isPokemonWithinLevelCap,
    getSelfHealingPercent,
    isSelfHealingMove,
    getSelfHealingAmount,
    getGymProgressionBlockReason,
    canAccessSSAnne,
    canAccessSilphCo,
  });

  root.GameRules = rules;
  if (typeof module !== 'undefined' && module.exports) module.exports = rules;
})(typeof globalThis !== 'undefined' ? globalThis : this);
