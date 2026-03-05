#import "ThemeManager.h"

NSString * const ThemeDidChangeNotification = @"ThemeDidChangeNotification";

static NSString * const kThemeBG = @"theme_bg_hex";
static NSString * const kThemeText = @"theme_text_hex";
static NSString * const kThemeSub = @"theme_sub_hex";
static NSString * const kThemeBorder = @"theme_border_hex";

static NSUserDefaults *ThemeUD(void) {
    return [NSUserDefaults standardUserDefaults];
}

static NSString *DefaultBG(void) { return @"#000000"; }
static NSString *DefaultText(void) { return @"#35FF7A"; }
static NSString *DefaultSub(void) { return @"#B3B3B3"; }
static NSString *DefaultBorder(void) { return @"#35FF7A"; }

static NSString *NormalizeHex(NSString *hex) {
    NSString *s = [[hex ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    if (s.length == 3) {
        unichar c0 = [s characterAtIndex:0];
        unichar c1 = [s characterAtIndex:1];
        unichar c2 = [s characterAtIndex:2];
        s = [NSString stringWithFormat:@"%C%C%C%C%C%C", c0, c0, c1, c1, c2, c2];
    }
    return s;
}

static BOOL IsValidHex(NSString *hex) {
    NSString *s = NormalizeHex(hex);
    if (!(s.length == 6 || s.length == 8)) return NO;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"] invertedSet];
    return [s rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static UIColor *ColorFromHexOrFallback(NSString *hex, UIColor *fallback) {
    NSString *s = NormalizeHex(hex);
    if (!(s.length == 6 || s.length == 8)) return fallback;

    unsigned int rgba = 0;
    NSScanner *scanner = [NSScanner scannerWithString:s];
    if (![scanner scanHexInt:&rgba]) return fallback;

    CGFloat r = 0, g = 0, b = 0, a = 1.0;
    if (s.length == 6) {
        r = ((rgba >> 16) & 0xFF) / 255.0;
        g = ((rgba >> 8) & 0xFF) / 255.0;
        b = (rgba & 0xFF) / 255.0;
    } else {
        r = ((rgba >> 24) & 0xFF) / 255.0;
        g = ((rgba >> 16) & 0xFF) / 255.0;
        b = ((rgba >> 8) & 0xFF) / 255.0;
        a = (rgba & 0xFF) / 255.0;
    }
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

NSDictionary<NSString *, NSString *> *ThemeCurrentHexStrings(void) {
    NSString *bg = [ThemeUD() stringForKey:kThemeBG] ?: DefaultBG();
    NSString *tx = [ThemeUD() stringForKey:kThemeText] ?: DefaultText();
    NSString *sb = [ThemeUD() stringForKey:kThemeSub] ?: DefaultSub();
    NSString *bd = [ThemeUD() stringForKey:kThemeBorder] ?: DefaultBorder();
    return @{ @"background": bg, @"primaryText": tx, @"secondaryText": sb, @"border": bd };
}

UIColor *ThemeBackgroundColor(void) {
    return ColorFromHexOrFallback([ThemeUD() stringForKey:kThemeBG], UIColor.blackColor);
}

UIColor *ThemePrimaryTextColor(void) {
    return ColorFromHexOrFallback([ThemeUD() stringForKey:kThemeText], UIColor.systemGreenColor);
}

UIColor *ThemeSecondaryTextColor(void) {
    return ColorFromHexOrFallback([ThemeUD() stringForKey:kThemeSub], UIColor.lightGrayColor);
}

UIColor *ThemeBorderColor(void) {
    return ColorFromHexOrFallback([ThemeUD() stringForKey:kThemeBorder], UIColor.systemGreenColor);
}

BOOL ThemeSetHexStrings(NSString *backgroundHex,
                        NSString *primaryTextHex,
                        NSString *secondaryTextHex,
                        NSString *borderHex,
                        NSString **errorMessage)
{
    if (!IsValidHex(backgroundHex) || !IsValidHex(primaryTextHex) || !IsValidHex(secondaryTextHex) || !IsValidHex(borderHex)) {
        if (errorMessage) *errorMessage = @"HEX形式は #RRGGBB または #RRGGBBAA";
        return NO;
    }

    [ThemeUD() setObject:[@"#" stringByAppendingString:NormalizeHex(backgroundHex)] forKey:kThemeBG];
    [ThemeUD() setObject:[@"#" stringByAppendingString:NormalizeHex(primaryTextHex)] forKey:kThemeText];
    [ThemeUD() setObject:[@"#" stringByAppendingString:NormalizeHex(secondaryTextHex)] forKey:kThemeSub];
    [ThemeUD() setObject:[@"#" stringByAppendingString:NormalizeHex(borderHex)] forKey:kThemeBorder];

    [[NSNotificationCenter defaultCenter] postNotificationName:ThemeDidChangeNotification object:nil];
    return YES;
}

void ThemeResetDefaults(void) {
    [ThemeUD() setObject:DefaultBG() forKey:kThemeBG];
    [ThemeUD() setObject:DefaultText() forKey:kThemeText];
    [ThemeUD() setObject:DefaultSub() forKey:kThemeSub];
    [ThemeUD() setObject:DefaultBorder() forKey:kThemeBorder];
    [[NSNotificationCenter defaultCenter] postNotificationName:ThemeDidChangeNotification object:nil];
}

void ThemeApplyGlobalAppearance(void) {
    UIColor *bg = ThemeBackgroundColor();
    UIColor *tx = ThemePrimaryTextColor();
    UIColor *sb = ThemeSecondaryTextColor();
    UIColor *bd = ThemeBorderColor();

    [UINavigationBar appearance].barTintColor = bg;
    [UINavigationBar appearance].tintColor = tx;
    [UINavigationBar appearance].titleTextAttributes = @{ NSForegroundColorAttributeName: tx };
    [UIBarButtonItem appearance].tintColor = tx;
    [UITableView appearance].backgroundColor = bg;
    [UITableViewCell appearance].backgroundColor = bg;
    [UILabel appearanceWhenContainedInInstancesOfClasses:@[UITableViewCell.class]].textColor = tx;
    [UILabel appearanceWhenContainedInInstancesOfClasses:@[UITableViewCell.class]].highlightedTextColor = tx;
    [UITextView appearance].backgroundColor = bg;
    [UITextView appearance].textColor = tx;
    [UITextField appearance].tintColor = tx;
    [UITextField appearance].textColor = tx;
    [UITextField appearance].backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    [UIButton appearance].tintColor = tx;
    [UIView appearanceWhenContainedInInstancesOfClasses:@[UITableViewCell.class]].tintColor = bd;
    (void)sb;
}
