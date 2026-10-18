#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C 例外（NSException）を Swift の throw に変換するための薄い橋渡し。
/// Swift は NSException を捕まえられず、AppKit の runloop が握りつぶすと
/// Swift Concurrency の実行状態を壊したまま処理が続き、後で無関係な場所で
/// SIGSEGV になる（2026-10-18 調査: AVAudioEngine.installTap の例外が原因）。
/// 例外を投げ得る AVFAudio 等の API はこれ越しに呼ぶ。
@interface KoeObjCException : NSObject

/// block を実行し、NSException が投げられたら NSError（domain = KoeObjCExceptionErrorDomain）に
/// 変換して NO を返す。Swift からは `try KoeObjCException.catching { ... }` で呼ぶ。
+ (BOOL)catchingException:(NS_NOESCAPE void (^)(void))block
                    error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(catching(_:));

#if TARGET_OS_OSX
/// AppKit が runloop 上で捕まえて握りつぶす例外（-[NSApplication reportException:]）を
/// handler へ通知する。挙動（握りつぶして続行）は変えず、記録だけを差し込む。
/// 多重に呼んでも最初の1回だけ有効。
+ (void)observeAppKitReportedExceptions:(void (^)(NSException *exception))handler
    NS_SWIFT_NAME(observeAppKitReportedExceptions(_:));
#endif

@end

FOUNDATION_EXPORT NSErrorDomain const KoeObjCExceptionErrorDomain;
/// userInfo のキー: 例外名（NSExceptionName の文字列）
FOUNDATION_EXPORT NSString * const KoeObjCExceptionNameKey;

NS_ASSUME_NONNULL_END
