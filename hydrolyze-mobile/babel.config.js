module.exports = function (api) {
  // When running pure Node/TS tests (no Expo platform), use minimal TypeScript transform
  if (api.caller((c) => c && c.name === 'jest-node')) {
    return {
      presets: [
        ['@babel/preset-typescript'],
        ['@babel/preset-react', { runtime: 'automatic' }],
      ],
      plugins: [
        '@babel/plugin-transform-modules-commonjs',
      ],
    };
  }

  // Default: Expo Metro transform for native/web tests
  return {
    presets: ['expo'],
  };
};
