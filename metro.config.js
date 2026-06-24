const {getDefaultConfig, mergeConfig} = require('@react-native/metro-config');

/**
 * Metro configuration
 * https://reactnative.dev/docs/metro
 *
 * @type {import('@react-native/metro-config').MetroConfig}
 */
const config = mergeConfig(getDefaultConfig(__dirname), {});

// Treat ".data" files as raw assets so Metro keeps them out of the main JS
// bundle. The CodePush marker lives in codepush-update-meta.data and is loaded
// at runtime; keeping it a separate asset means a marker-only change produces a
// tiny CodePush diff (the asset + hotcodepush.json) instead of regenerating the
// whole bundle.
config.resolver.assetExts = [...config.resolver.assetExts, 'data'];

module.exports = config;
