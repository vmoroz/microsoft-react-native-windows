/**
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License.
 *
 * @format
 * @ts-check
 */

const path = require('path');
const fs = require('fs');

function normalizeBool(value) {
  if (value === undefined || value === null) {
    return undefined;
  }

  const normalized = String(value).trim().toLowerCase();
  if (normalized === 'true' || normalized === '1') {
    return true;
  }
  if (normalized === 'false' || normalized === '0') {
    return false;
  }

  return undefined;
}

function readUseHermesFromExperimentalFeatures(projectRoot) {
  const windowsDir = path.join(projectRoot, 'windows');
  if (!fs.existsSync(windowsDir)) {
    return undefined;
  }

  const candidates = [];
  const rootCandidate = path.join(windowsDir, 'ExperimentalFeatures.props');
  if (fs.existsSync(rootCandidate)) {
    candidates.push(rootCandidate);
  }

  const entries = fs.readdirSync(windowsDir);
  for (const entryName of entries) {
    const entryPath = path.join(windowsDir, entryName);
    if (!fs.existsSync(entryPath) || !fs.statSync(entryPath).isDirectory()) {
      continue;
    }

    const candidate = path.join(
      windowsDir,
      entryName,
      'ExperimentalFeatures.props',
    );
    if (fs.existsSync(candidate)) {
      candidates.push(candidate);
    }
  }

  for (const filePath of candidates) {
    const contents = fs.readFileSync(filePath, 'utf8');
    const match = contents.match(
      /<UseHermes>\s*(true|false|1|0)\s*<\/UseHermes>/i,
    );
    if (match) {
      return normalizeBool(match[1]);
    }
  }

  return undefined;
}

function resolveUseHermes(env) {
  let envValue = normalizeBool(env.USE_HERMES);
  if (envValue === undefined) {
    envValue = normalizeBool(env.RNW_USE_HERMES);
  }
  if (envValue === undefined) {
    envValue = normalizeBool(env.REACT_NATIVE_USE_HERMES);
  }

  if (envValue !== undefined) {
    return envValue;
  }

  const projectRoot = env.INIT_CWD || env.RNW_PROJECT_ROOT || process.cwd();
  return readUseHermesFromExperimentalFeatures(projectRoot);
}

module.exports = () => {
  const useHermes = resolveUseHermes(process.env);
  const transformProfile = useHermes === false ? 'default' : 'hermes-stable';

  const plugins = [
    'babel-plugin-transform-flow-enums',
    '@babel/plugin-transform-named-capturing-groups-regex',
  ];

  // Ensure object spread/rest is always transpiled for Chakra
  if (useHermes === false) {
    plugins.push([
      require('@babel/plugin-transform-object-rest-spread'),
      {loose: true, useBuiltIns: true},
    ]);
    plugins.push([require('@babel/plugin-transform-spread'), {loose: true}]);
  }

  return {
    presets: [
      [
        'module:@react-native/babel-preset',
        {
          disableDeepImportWarnings: true,
          unstable_transformProfile: transformProfile,
        },
      ],
    ],
    plugins,
  };
};
