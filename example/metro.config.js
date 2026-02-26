const { getDefaultConfig } = require("expo/metro-config");
const path = require("path");

const projectRoot = __dirname;
const monorepoRoot = path.resolve(projectRoot, "..");

const config = getDefaultConfig(projectRoot);

// Watch the parent directory (the library source)
config.watchFolders = [monorepoRoot];

// Block parent node_modules from being resolved (prevents duplicate React)
// Use a regex to exclude everything under NewLibrary/node_modules
const parentNodeModules = path.resolve(monorepoRoot, "node_modules");
const escapedPath = parentNodeModules.replace(/[/\\]/g, "[/\\\\]");
config.resolver.blockList = [new RegExp(`^${escapedPath}[/\\\\].*$`)];

// Resolve modules from example/node_modules only
config.resolver.nodeModulesPaths = [path.resolve(projectRoot, "node_modules")];

module.exports = config;
