const expoConfig = require("eslint-config-expo/flat");

module.exports = [
  ...expoConfig,
  {
    ignores: ["build/**", "node_modules/**", "example/**"],
  },
  {
    files: ["**/*.ts", "**/*.tsx"],
    rules: {
      // Already handled by TypeScript
      "no-redeclare": "off",
      "@typescript-eslint/no-redeclare": "off",
      "no-unused-expressions": "off",
      "no-unused-vars": "off",
      "@typescript-eslint/no-unused-expressions": "off",
      "@typescript-eslint/no-unused-vars": "off",
    },
  },
];
