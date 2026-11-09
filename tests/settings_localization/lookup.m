// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import <Foundation/Foundation.h>

static unsigned checks, failures, lookups;
static void check(BOOL ok, NSString *message) {
    checks++; if (!ok) { failures++; fprintf(stderr,"FAIL %s\n",message.UTF8String); }
}
static NSDictionary *plist(NSString *path) {
    NSError *error=nil; NSData *data=[NSData dataWithContentsOfFile:path options:0 error:&error];
    id value=data?[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:&error]:nil;
    check([value isKindOfClass:NSDictionary.class],[@"Foundation reads " stringByAppendingString:path]);
    return [value isKindOfClass:NSDictionary.class]?value:@{};
}
static NSString *text(NSBundle *bundle, NSString *key, NSString *table, NSString *language) {
    // Inspect exactly the requested shipped localization. Looking up the root
    // bundle would let Foundation choose its only localization (Chinese) even
    // for English. Settings' default English text resides in Root.plist.
    NSString *directory=[bundle pathForResource:language ofType:@"lproj"];
    if(!directory) return key;
    NSBundle *localized=[NSBundle bundleWithPath:directory];
    check(localized!=nil,[@"Foundation opens " stringByAppendingString:directory]);
    lookups++;
    return [localized localizedStringForKey:key value:key table:table];
}
// Settings' Values/Titles display mapping: values outside the fixed list are
// actual package metadata and must pass through. This does not emulate UIKit.
static NSString *display(NSDictionary *spec, NSString *value, NSBundle *bundle, NSString *table, NSString *language) {
    NSUInteger index=[spec[@"Values"] indexOfObject:value];
    return index!=NSNotFound && index<[spec[@"Titles"] count]?text(bundle,spec[@"Titles"][index],table,language):value;
}
int main(int argc, char **argv) { @autoreleasepool {
    if(argc!=3) return 2;
    NSString *path=[NSString stringWithUTF8String:argv[1]], *hostPath=[NSString stringWithUTF8String:argv[2]];
    NSDictionary *root=plist([path stringByAppendingPathComponent:@"Root.plist"]);
    // Settings defaults to Root.strings when StringsTable is omitted, as main
    // deliberately does. Do not require the previous PR's explicit table/en file.
    NSString *table=root[@"StringsTable"]?:@"Root";
    check([table isEqual:@"Root"],@"Settings uses its default Root table");
    NSArray *specs=root[@"PreferenceSpecifiers"]; check(specs.count==27,@"27 real Settings elements");
    NSBundle *bundle=[NSBundle bundleWithPath:path], *host=[NSBundle bundleWithPath:hostPath];
    check(bundle!=nil && host!=nil,@"Foundation opens shipped Settings and host localization bundles");
    NSDictionary *zh=plist([path stringByAppendingPathComponent:@"zh-Hans.lproj/Root.strings"]);
    NSDictionary *defaults=@{@"S2APhoneGyro":@YES,@"S2APhoneHaptics":@YES,@"S2ADockedMode":@NO,
        @"S2AResolutionScale":@"1",@"S2AAntiAliasing":@"None",@"S2AScalingFilter":@"Bilinear",@"S2AFrameRateLimit":@"0",
        @"S2ANS2ProAdapterEnabled":@NO,@"S2ASaveManageOnOpen":@NO,@"S2ADiagExportOnOpen":@NO,@"S2ADevHUD":@NO,@"MetalHUDForceEnabled":@NO,
        @"S2AGraphicsModeText":@"unknown",@"S2ADirectLibVersionText":@"unknown",@"S2APackTimeText":@"unknown",@"S2ABuildIDText":@"unknown"};
    NSDictionary *values=@{@"S2AResolutionScale":@[@"0.5",@"0.75",@"1",@"1.5",@"2"],@"S2AAntiAliasing":@[@"None",@"SmaaMedium",@"SmaaHigh"],
        @"S2AScalingFilter":@[@"Bilinear",@"Nearest"],@"S2AFrameRateLimit":@[@"30",@"60",@"120",@"0"]};
    NSDictionary *expected=@{@"Phone Gyro":@"手机陀螺仪",@"Docked Mode":@"主机模式",@"Anti-Aliasing":@"抗锯齿",@"Build ID":@"包号",
        @"1× (Native)":@"1×（原生）",@"Unlimited":@"不限",@"Unknown (shown after opening a game once)":@"未知（打开一次游戏后显示）"};
    NSMutableSet *seen=[NSMutableSet set]; unsigned readOnly=0, fields=0;
    for(NSDictionary *spec in specs) {
        NSString *key=spec[@"Key"];
        if(key) {
            check(![seen containsObject:key] && defaults[key]!=nil,[@"unique existing preference " stringByAppendingString:key]); [seen addObject:key];
            check([spec[@"DefaultValue"] isEqual:defaults[key]],[@"stable persisted default " stringByAppendingString:key]);
            if(values[key]) check([spec[@"Values"] isEqual:values[key]],[@"stable persisted choices " stringByAppendingString:key]);
        }
        NSMutableArray *strings=[NSMutableArray array];
        for(NSString *field in @[@"Title",@"FooterText"]) if(spec[field]) [strings addObject:spec[field]];
        [strings addObjectsFromArray:spec[@"Titles"]?:@[]];
        for(NSString *s in strings) {
            fields++;
            check([s rangeOfString:@"[\\p{Han}]" options:NSRegularExpressionSearch].location==NSNotFound,[@"English default field " stringByAppendingString:s]);
            check([text(bundle,s,table,@"en") isEqual:s],[@"English default / localized display " stringByAppendingString:s]);
            check([text(bundle,s,table,@"fr") isEqual:s],[@"untranslated language uses English source " stringByAppendingString:s]);
            NSString *chinese=text(bundle,s,table,@"zh-Hans");
            BOOL needsTranslation=[s rangeOfString:@"[A-Za-z]" options:NSRegularExpressionSearch].location!=NSNotFound;
            check(chinese.length && (!needsTranslation || ([zh[s] isKindOfClass:NSString.class] && [chinese isEqual:zh[s]])),[@"Foundation Chinese field " stringByAppendingString:s]);
            if(expected[s]) check([chinese isEqual:expected[s]],[@"independent Chinese expectation " stringByAppendingString:s]);
        }
        if([spec[@"Type"] isEqual:@"PSTitleValueSpecifier"]) {
            readOnly++;
            check([spec[@"Values"] isEqual:@[@"unknown"]] && [spec[@"Titles"] isEqual:@[@"Unknown (shown after opening a game once)"]],@"main's fixed read-only unknown mapping");
            check([display(spec,@"unknown",bundle,table,@"en") isEqual:@"Unknown (shown after opening a game once)"],@"English read-only prelaunch display");
            check([display(spec,@"unknown",bundle,table,@"zh-Hans") isEqual:expected[@"Unknown (shown after opening a game once)"]],@"Chinese read-only prelaunch display");
            for(NSString *language in @[@"en",@"zh-Hans"]) {
                for(NSString *v in @[@"v0.1.9-abc123",@"2026-11-10T06:00:00Z",@"abc123def-0042"])
                    check([display(spec,v,bundle,table,language) isEqual:v],@"actual version/build/time values pass through");
                // settings.m publishes these four S2ArmHost keys using S2AL.
                // Test their real tables as values, not the old PR's status map.
                for(NSString *status in @[@"about.mode.direct",@"about.mode.unrecorded",@"about.directLib.none",@"about.unknown"]) {
                    NSString *v=text(host,status,@"S2ArmHost",language);
                    check(v.length && ![v isEqual:status],[@"host fixed status exists " stringByAppendingString:status]);
                    check([display(spec,v,bundle,table,language) isEqual:v],@"published localized fixed status passes through");
                }
            }
        }
    }
    check(seen.count==16 && readOnly==4,@"16 preferences and four read-only rows");
    printf("Settings Foundation localization: %u checks, %u failures; %u fields, %u real bundle lookups\n",checks,failures,fields,lookups);
    return failures?1:0;
} }
