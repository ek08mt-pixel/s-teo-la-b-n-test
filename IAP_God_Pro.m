#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <StoreKit/StoreKit.h>

#pragma mark - Fake Transaction

@interface FakeTransaction : NSObject
@property (nonatomic, copy) NSString *productIdentifier;
@property (nonatomic, copy) NSString *transactionIdentifier;
@property (nonatomic, copy) NSDate *transactionDate;
@property (nonatomic, assign) NSInteger transactionState;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, strong) NSData *transactionReceipt;
@property (nonatomic, strong) SKPayment *payment;
@end

@implementation FakeTransaction
- (instancetype)initWithProductId:(NSString *)pid {
    self = [super init];
    if (self) {
        _productIdentifier = pid;
        _transactionIdentifier = [[NSUUID UUID] UUIDString];
        _transactionDate = [NSDate date];
        _transactionState = 1; // Purchased
        _transactionReceipt = [NSData dataWithBytes:"receipt" length:7];
    }
    return self;
}
@end

#pragma mark - SKPaymentQueue Hook

static void (*orig_addPayment)(id, SEL, SKPayment*);
static void hook_addPayment(SKPaymentQueue *self, SEL _cmd, SKPayment *payment) {
    FakeTransaction *fake = [[FakeTransaction alloc] initWithProductId:payment.productIdentifier];
    fake.payment = payment;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *observers = [self valueForKey:@"transactionObservers"];
        for (id obs in observers) {
            if ([obs respondsToSelector:@selector(paymentQueue:updatedTransactions:)]) {
                [obs paymentQueue:self updatedTransactions:@[fake]];
            }
        }
    });
}

static void (*orig_finishTransaction)(id, SEL, id);
static void hook_finishTransaction(id self, SEL _cmd, id t) {
    orig_finishTransaction(self, _cmd, t);
}

static id (*orig_transactions)(id, SEL);
static id hook_transactions(id self, SEL _cmd) { return @[]; }

#pragma mark - SKProductsRequest Hook

static void (*orig_didReceiveResponse)(id, SEL, id, id);
static void hook_didReceiveResponse(id self, SEL _cmd, id req, id response) {
    NSArray *products = [response valueForKey:@"products"];
    for (id p in products) {
        @try {
            [p setValue:@(0.00) forKey:@"price"];
            [p setValue:@"₫0" forKey:@"priceString"];
        } @catch (NSException *e) {}
    }
    orig_didReceiveResponse(self, _cmd, req, response);
}

static void (*orig_didFailWithError)(id, SEL, id, id);
static void hook_didFailWithError(id self, SEL _cmd, id req, id err) {
    // Tự sinh response fake
    Class SR = NSClassFromString(@"SKProductsResponse");
    if (SR && [req respondsToSelector:@selector(productIdentifiers)]) {
        NSSet *ids = [req valueForKey:@"productIdentifiers"];
        NSMutableArray *fakeProducts = [NSMutableArray array];
        for (NSString *pid in ids) {
            id fp = [[NSClassFromString(@"SKProduct") alloc] init];
            [fp setValue:pid forKey:@"productIdentifier"];
            [fp setValue:@"Fake Product" forKey:@"localizedTitle"];
            [fp setValue:@"Free" forKey:@"localizedDescription"];
            [fp setValue:@(0.00) forKey:@"price"];
            [fakeProducts addObject:fp];
        }
        id fakeResp = [[SR alloc] init];
        [fakeResp setValue:fakeProducts forKey:@"products"];
        [fakeResp setValue:@[] forKey:@"invalidProductIdentifiers"];
        if ([self respondsToSelector:@selector(productsRequest:didReceiveResponse:)]) {
            [self productsRequest:req didReceiveResponse:fakeResp];
        }
    }
}

#pragma mark - NSURLSession/Connection Hook (Chặn API verify receipt)

static id (*orig_NSURLSession_dataTaskWithRequest)(id, SEL, id, id);
static id hook_NSURLSession_dataTaskWithRequest(id self, SEL _cmd, id request, id handler) {
    NSURL *url = [request valueForKey:@"URL"];
    NSString *urlStr = [url absoluteString];
    NSString *body = [[NSString alloc] initWithData:[request valueForKey:@"HTTPBody"] encoding:NSUTF8StringEncoding];
    
    if ([urlStr containsString:@"verifyReceipt"] || 
        [urlStr containsString:@"verify"] ||
        [urlStr containsString:@"iap"] ||
        [urlStr containsString:@"purchase"] ||
        [urlStr containsString:@"buy"] ||
        [urlStr containsString:@"payment"] ||
        [urlStr containsString:@"receipt"] ||
        [urlStr containsString:@"unlock"] ||
        [urlStr containsString:@"order"] ||
        [urlStr containsString:@"premium"] ||
        [urlStr containsString:@"vip"]) {
        
        // Fake response JSON
        NSDictionary *fakeJson = @{
            @"status": @0,
            @"code": @200,
            @"success": @YES,
            @"data": @{
                @"purchase": @YES,
                @"unlocked": @YES,
                @"premium": @YES,
                @"vip": @YES,
                @"receipt_valid": @YES,
                @"order_id": [[NSUUID UUID] UUIDString]
            },
            @"message": @"OK"
        };
        
        NSData *fakeData = [NSJSONSerialization dataWithJSONObject:fakeJson options:0 error:nil];
        NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc] 
            initWithURL:url 
            statusCode:200 
            HTTPVersion:@"HTTP/1.1" 
            headerFields:@{@"Content-Type": @"application/json"}];
        
        if (handler) {
            ((void(^)(NSData*, NSURLResponse*, NSError*))handler)(fakeData, fakeResp, nil);
        }
        return nil;
    }
    
    return orig_NSURLSession_dataTaskWithRequest(self, _cmd, request, handler);
}

static id (*orig_NSURLConnection_sendSync)(id, SEL, id, id, id);
static id hook_NSURLConnection_sendSync(id self, SEL _cmd, id request, id response, id error) {
    NSURL *url = [request valueForKey:@"URL"];
    NSString *urlStr = [url absoluteString];
    
    if ([urlStr containsString:@"verifyReceipt"] || 
        [urlStr containsString:@"iap"] ||
        [urlStr containsString:@"purchase"] ||
        [urlStr containsString:@"buy"] ||
        [urlStr containsString:@"premium"] ||
        [urlStr containsString:@"vip"]) {
        
        NSDictionary *fakeJson = @{@"status":@0, @"code":@200, @"success":@YES};
        NSData *fakeData = [NSJSONSerialization dataWithJSONObject:fakeJson options:0 error:nil];
        
        if (response) {
            id httpResp = [[NSHTTPURLResponse alloc] 
                initWithURL:url 
                statusCode:200 
                HTTPVersion:@"HTTP/1.1" 
                headerFields:@{@"Content-Type": @"application/json"}];
            id *respPtr = (id *)response;
            *respPtr = httpResp;
        }
        return fakeData;
    }
    
    return orig_NSURLConnection_sendSync ? orig_NSURLConnection_sendSync(self, _cmd, request, response, error) : nil;
}

#pragma mark - NSUserDefaults Hook

static id (*orig_obj)(id, SEL, NSString*);
static id hook_obj(id self, SEL _cmd, NSString *key) {
    NSString *k = [key lowercaseString];
    if ([k containsString:@"iap"]||[k containsString:@"purchase"]||[k containsString:@"unlock"]||
        [k containsString:@"premium"]||[k containsString:@"vip"]||[k containsString:@"pro"]||
        [k containsString:@"buy"]||[k containsString:@"paid"]||[k containsString:@"member"]||
        [k containsString:@"subscription"]||[k containsString:@"diamond"]||[k containsString:@"coin"]) {
        return @"1";
    }
    if ([k containsString:@"expire"]) return @(4102444800);
    return orig_obj ? orig_obj(self, _cmd, key) : nil;
}

static BOOL (*orig_bool)(id, SEL, NSString*);
static BOOL hook_bool(id self, SEL _cmd, NSString *key) {
    NSString *k = [key lowercaseString];
    if ([k containsString:@"iap"]||[k containsString:@"purchase"]||[k containsString:@"unlock"]||
        [k containsString:@"premium"]||[k containsString:@"vip"]||[k containsString:@"pro"]||
        [k containsString:@"buy"]||[k containsString:@"paid"]||[k containsString:@"member"]||
        [k containsString:@"subscription"]) return YES;
    if ([k containsString:@"trial"]) return NO;
    return orig_bool ? orig_bool(self, _cmd, key) : NO;
}

#pragma mark - Keychain Hook

static id (*orig_keychain_query)(id, SEL, id);
static id hook_keychain_query(id self, SEL _cmd, id query) {
    id result = orig_keychain_query ? orig_keychain_query(self, _cmd, query) : nil;
    NSString *service = [query valueForKey:(id)kSecAttrService];
    if ([service containsString:@"receipt"] || [service containsString:@"purchase"]) {
        return (__bridge id)[NSData dataWithBytes:"receipt" length:7];
    }
    return result;
}

#pragma mark - Runtime Class Hook

static void hookSelectors(void) {
    unsigned int count;
    Class *classes = objc_copyClassList(&count);
    const char *sels[] = {
        "isPurchased","isUnlocked","isPremium","hasPurchased",
        "isIAPPurchased","isProductPurchased","isItemUnlocked",
        "isVIP","isVip","isPro","hasVIP","hasPremium",
        "hasSubscription","isSubscribed","isMember",
        "isFeatureUnlocked","isFullVersion","isPaidUser",
        NULL
    };
    for (unsigned int i = 0; i < count; i++) {
        for (int j = 0; sels[j] != NULL; j++) {
            SEL s = sel_registerName(sels[j]);
            Method m = class_getInstanceMethod(classes[i], s);
            if (m) {
                IMP imp = imp_implementationWithBlock(^BOOL(id self, SEL _cmd) { return YES; });
                method_setImplementation(m, imp);
            }
            m = class_getClassMethod(classes[i], s);
            if (m) {
                IMP imp = imp_implementationWithBlock(^BOOL(id self, SEL _cmd) { return YES; });
                method_setImplementation(m, imp);
            }
        }
    }
    free(classes);
}

#pragma mark - Constructor

__attribute__((constructor))
static void IAPGodProInit() {
    @autoreleasepool {
        // SKPaymentQueue
        Class q = [SKPaymentQueue class];
        Method m1 = class_getInstanceMethod(q, @selector(addPayment:));
        if(m1){orig_addPayment=(void*)method_getImplementation(m1);method_setImplementation(m1,(IMP)hook_addPayment);}
        Method m2 = class_getInstanceMethod(q, @selector(finishTransaction:));
        if(m2){orig_finishTransaction=(void*)method_getImplementation(m2);method_setImplementation(m2,(IMP)hook_finishTransaction);}
        Method m3 = class_getInstanceMethod(q, @selector(transactions));
        if(m3){orig_transactions=(void*)method_getImplementation(m3);method_setImplementation(m3,(IMP)hook_transactions);}
        
        // NSUserDefaults
        Class ud = [NSUserDefaults class];
        Method m4 = class_getInstanceMethod(ud, @selector(objectForKey:));
        if(m4){orig_obj=(void*)method_getImplementation(m4);method_setImplementation(m4,(IMP)hook_obj);}
        Method m5 = class_getInstanceMethod(ud, @selector(boolForKey:));
        if(m5){orig_bool=(void*)method_getImplementation(m5);method_setImplementation(m5,(IMP)hook_bool);}
        Method m6 = class_getInstanceMethod(ud, @selector(stringForKey:));
        if(m6) method_setImplementation(m6, (IMP)hook_obj);
        Method m7 = class_getInstanceMethod(ud, @selector(valueForKey:));
        if(m7) method_setImplementation(m7, (IMP)hook_obj);
        Method m8 = class_getInstanceMethod(ud, @selector(dictionaryForKey:));
        if(m8) method_setImplementation(m8, (IMP)hook_obj);
        Method m9 = class_getInstanceMethod(ud, @selector(arrayForKey:));
        if(m9) method_setImplementation(m9, (IMP)hook_obj);
        
        // NSURLSession
        Class session = [NSURLSession class];
        Method m10 = class_getInstanceMethod(session, @selector(dataTaskWithRequest:completionHandler:));
        if(m10){orig_NSURLSession_dataTaskWithRequest=(void*)method_getImplementation(m10);method_setImplementation(m10,(IMP)hook_NSURLSession_dataTaskWithRequest);}
        
        // NSURLConnection
        Class conn = [NSURLConnection class];
        Method m11 = class_getClassMethod(conn, @selector(sendSynchronousRequest:returningResponse:error:));
        if(m11){orig_NSURLConnection_sendSync=(void*)method_getImplementation(m11);method_setImplementation(m11,(IMP)hook_NSURLConnection_sendSync);}
        
        // Keychain
        Class kc = NSClassFromString(@"SFHFKeychainUtils");
        if (kc) {
            Method m12 = class_getClassMethod(kc, @selector(getPasswordForUsername:andServiceName:error:));
            if(m12){orig_keychain_query=(void*)method_getImplementation(m12);method_setImplementation(m12,(IMP)hook_keychain_query);}
        }
        
        // SKProductsRequest
        Class pr = [SKProductsRequest class];
        Method m13 = class_getInstanceMethod(pr, @selector(start));
        if (m13) {
            // Hook delegate setter để bắt response
            Method m13b = class_getInstanceMethod(pr, @selector(setDelegate:));
            if (m13b) {
                // Swizzle để hook didReceiveResponse
            }
        }
        
        // Hook all runtime classes
        hookSelectors();
        
        NSLog(@"[IAP_GOD_PRO] ===== ALL IAP + API BYPASSED =====");
    }
}
