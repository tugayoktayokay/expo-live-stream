// React Native autolinking description for the plain-RN path.
//
// This used to return `null` per platform whenever the host app looked like an
// Expo app, to stop the package being linked twice. That is actively harmful
// from Expo SDK 53 onwards: Expo autolinking took over React Native's own
// autolinking, and it reads this file too - a `null` platform now means "never
// link this package", so the Expo module never reaches ExpoModulesProvider and
// every view renders as `UnimplementedView`.
//
// Describing the platforms unconditionally is safe in both worlds. In a bare
// React Native app this is the only thing that links the package. In an Expo
// app the Expo module is registered from `expo-module.config.json` and this
// description resolves to the same pod / Gradle project, so nothing is built
// twice; the JS side then picks whichever native path is actually present.
module.exports = {
  dependency: {
    platforms: {
      android: {
        sourceDir: './android',
        packageImportPath: 'import expo.modules.livestream.ExpoLiveStreamPackage;',
        packageInstance: 'new ExpoLiveStreamPackage()',
      },
      ios: {},
    },
  },
};
