import { NativeModules, requireNativeComponent } from "react-native";

/**
 * Minimal shape of a React Native static view config. It mirrors
 * `PartialViewConfig` from React Native, which is not part of the public API
 * surface, so it is restated here rather than imported.
 */
export type StaticViewConfig = {
  uiViewClassName: string;
  bubblingEventTypes?: Record<string, unknown>;
  directEventTypes?: Record<string, { registrationName: string }>;
  validAttributes?: Record<string, unknown>;
};

let cachedExpoCore: any | undefined;

function requireExpoCore(): any | null {
  if (cachedExpoCore !== undefined) {
    return cachedExpoCore;
  }
  try {
    // Lazy on purpose: the package is an optional peer, so it must not be
    // resolved at module-evaluation time. Importing it is also what installs
    // `globalThis.expo`, so it has to happen before that global is read.
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    cachedExpoCore = require("expo-modules-core");
  } catch {
    cachedExpoCore = null;
  }
  return cachedExpoCore;
}

function hasExpoNativeCore(): boolean {
  if (!requireExpoCore()) {
    return false;
  }
  // The JS package alone proves nothing: in a bare React Native app it can be
  // installed while the native side is not, in which case `installModules()`
  // quietly does nothing. `globalThis.expo.getViewConfig` is installed by
  // ExpoModulesCore itself, so it is the signal that the Expo path is really
  // available.
  return typeof (globalThis as any).expo?.getViewConfig === "function";
}

function fromExpo(viewName: string): React.ComponentType<any> | null {
  try {
    return requireExpoCore()?.requireNativeViewManager(viewName) ?? null;
  } catch {
    return null;
  }
}

/**
 * Components already handed out, keyed by view name. Registering the same name
 * twice makes React Native throw "Tried to register two views with the same
 * name", which happens on Fast Refresh and when two copies of this package end
 * up in the tree, so resolution has to be memoised.
 */
const resolvedViews = new Map<string, React.ComponentType<any>>();

function fromStaticViewConfig(
  viewConfig: StaticViewConfig,
): React.ComponentType<any> | null {
  try {
    // React Native resolves a host component's view config in one of two ways:
    // on the old architecture it reflects over the native ViewManager, on the
    // new architecture (bridgeless) that reflection is gone unless the app
    // opts into `useNativeViewConfigsInBridgelessMode`, which a library cannot
    // require of its host. Registering the config statically covers both: the
    // registry prefers the native config on the old architecture and the
    // static one on the new. This is the same approach ExpoModulesCore takes.
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const registry = require("react-native/Libraries/NativeComponent/NativeComponentRegistry");
    return registry.get(viewConfig.uiViewClassName, () => viewConfig);
  } catch {
    return null;
  }
}

/**
 * Resolves the native view backing `viewConfig.uiViewClassName`, preferring the
 * Expo module when the host app has ExpoModulesCore and falling back to the
 * plain React Native ViewManager otherwise.
 */
export function resolveNativeView(
  viewConfig: StaticViewConfig,
): React.ComponentType<any> | null {
  const viewName = viewConfig.uiViewClassName;

  const cached = resolvedViews.get(viewName);
  if (cached) {
    return cached;
  }

  const resolved = resolveNativeViewUncached(viewConfig, viewName);
  if (resolved) {
    resolvedViews.set(viewName, resolved);
  }
  return resolved;
}

function resolveNativeViewUncached(
  viewConfig: StaticViewConfig,
  viewName: string,
): React.ComponentType<any> | null {
  if (hasExpoNativeCore()) {
    const expoView = fromExpo(viewName);
    if (expoView) {
      return expoView;
    }
  }

  const staticView = fromStaticViewConfig(viewConfig);
  if (staticView) {
    return staticView;
  }

  try {
    return requireNativeComponent(viewName);
  } catch (e) {
    console.warn(`[ExpoLiveStream] Native view '${viewName}' not found:`, e);
    return null;
  }
}

/**
 * Resolves the native module exposing the imperative commands for a view.
 */
export function resolveNativeModule<T extends Record<string, unknown>>(
  moduleName: string,
): Partial<T> | null {
  if (hasExpoNativeCore()) {
    try {
      const expoModule = requireExpoCore()?.requireNativeModule(moduleName) as
        | Partial<T>
        | undefined;
      if (expoModule) {
        return expoModule;
      }
    } catch {
      // fall through to React Native NativeModules
    }
  }

  const rnModules = NativeModules as Record<string, Partial<T> | undefined>;
  const existing = rnModules[moduleName] ?? null;
  if (existing) {
    return existing;
  }

  console.warn(
    `[ExpoLiveStream] Native module '${moduleName}' is unavailable; ` +
      "imperative commands (start/stop/...) will do nothing.",
  );
  return null;
}
