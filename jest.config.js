module.exports = {
  preset: 'react-native',
  // ".data" is a raw asset (the runtime CodePush marker); map it to a stub so
  // `require('./codepush-update-meta.data')` resolves under Jest, mirroring how
  // image assets are stubbed.
  moduleNameMapper: {
    '\\.data$': '<rootDir>/__mocks__/assetMock.js',
  },
};
