#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString * const ThemeDidChangeNotification;

#ifdef __cplusplus
extern "C" {
#endif

UIColor *ThemeBackgroundColor(void);
UIColor *ThemePrimaryTextColor(void);
UIColor *ThemeSecondaryTextColor(void);
UIColor *ThemeBorderColor(void);

NSDictionary<NSString *, NSString *> *ThemeCurrentHexStrings(void);
BOOL ThemeSetHexStrings(NSString *backgroundHex,
                        NSString *primaryTextHex,
                        NSString *secondaryTextHex,
                        NSString *borderHex,
                        NSString **errorMessage);

void ThemeResetDefaults(void);
void ThemeApplyGlobalAppearance(void);

#ifdef __cplusplus
}
#endif
