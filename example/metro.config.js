const { getDefaultConfig } = require("expo/metro-config");
const path = require("path");

const projectRoot = __dirname;
const workspaceRoot = path.resolve(projectRoot, "..");

const config = getDefaultConfig(projectRoot);

// Watch the parent directory (library source)
config.watchFolders = [workspaceRoot];

// Block parent's node_modules to prevent duplicate React/RN
const parentNodeModules = path.resolve(workspaceRoot, "node_modules");
const escapedPath = parentNodeModules.replace(/[/\\]/g, "[/\\\\]");

config.resolver.blockList = [new RegExp(`${escapedPath}[/\\\\].*`)];

// Resolve all node_modules from the example's folder only
config.resolver.nodeModulesPaths = [path.resolve(projectRoot, "node_modules")];

module.exports = config;
