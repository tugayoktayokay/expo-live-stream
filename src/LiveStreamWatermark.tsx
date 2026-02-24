import React from 'react';
import {
  View,
  Image,
  Text,
  StyleSheet,
  type ViewStyle,
  type ImageSourcePropType,
  type TextStyle,
} from 'react-native';

// ─── Types ───────────────────────────────────────────────────

export type WatermarkPosition =
  | 'top-left'
  | 'top-right'
  | 'bottom-left'
  | 'bottom-right'
  | 'center';

export interface WatermarkProps {
  /** Position of the watermark on the stream view */
  position?: WatermarkPosition;
  /** Image source (require() or { uri: '...' }) */
  image?: ImageSourcePropType;
  /** Text watermark (shown if no image provided) */
  text?: string;
  /** Opacity of the watermark (0-1, default: 0.7) */
  opacity?: number;
  /** Size of the watermark image in pixels (default: 60) */
  size?: number;
  /** Margin from edges in pixels (default: 16) */
  margin?: number;
  /** Custom text style */
  textStyle?: TextStyle;
  /** Custom container style (overrides position) */
  style?: ViewStyle;
}

/**
 * Overlay watermark component for live streams.
 * Place this as a sibling AFTER ExpoLiveStreamPublisherView inside a container.
 *
 * @example
 * ```tsx
 * <View style={{ flex: 1 }}>
 *   <ExpoLiveStreamPublisherView ref={ref} style={{ flex: 1 }} url="..." />
 *   <LiveStreamWatermark
 *     image={require('./logo.png')}
 *     position="top-right"
 *     opacity={0.5}
 *     size={48}
 *   />
 * </View>
 * ```
 *
 * @example Text watermark
 * ```tsx
 * <LiveStreamWatermark
 *   text="LIVE"
 *   position="top-left"
 *   textStyle={{ fontSize: 14, fontWeight: 'bold', color: '#e74c3c' }}
 * />
 * ```
 */
export function LiveStreamWatermark({
  position = 'top-right',
  image,
  text,
  opacity = 0.7,
  size = 60,
  margin = 16,
  textStyle,
  style,
}: WatermarkProps) {
  const positionStyle = getPositionStyle(position, margin);

  return (
    <View
      style={[styles.container, positionStyle, { opacity }, style]}
      pointerEvents="none"
    >
      {image ? (
        <Image
          source={image}
          style={{ width: size, height: size, resizeMode: 'contain' }}
        />
      ) : text ? (
        <View style={styles.textBadge}>
          <Text style={[styles.defaultText, textStyle]}>{text}</Text>
        </View>
      ) : null}
    </View>
  );
}

// ─── Helpers ─────────────────────────────────────────────────

function getPositionStyle(
  position: WatermarkPosition,
  margin: number,
): ViewStyle {
  switch (position) {
    case 'top-left':
      return { top: margin, left: margin };
    case 'top-right':
      return { top: margin, right: margin };
    case 'bottom-left':
      return { bottom: margin, left: margin };
    case 'bottom-right':
      return { bottom: margin, right: margin };
    case 'center':
      return {
        top: '50%',
        left: '50%',
        transform: [{ translateX: -30 }, { translateY: -30 }],
      } as ViewStyle;
    default:
      return { top: margin, right: margin };
  }
}

const styles = StyleSheet.create({
  container: {
    position: 'absolute',
    zIndex: 10,
  },
  textBadge: {
    backgroundColor: 'rgba(0, 0, 0, 0.5)',
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 6,
  },
  defaultText: {
    color: '#fff',
    fontSize: 12,
    fontWeight: '600',
  },
});

export default LiveStreamWatermark;
