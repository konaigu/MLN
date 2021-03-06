//
//  MLNUIDataBinding.m
// MLNUI
//
//  Created by Dai Dongpeng on 2020/3/3.
//

#import "MLNUIDataBinding.h"
#import <pthread.h>
#import "NSMutableArray+MLNUIKVO.h"
#import "NSArray+MLNUIKVO.h"
#import "MLNUIExtScope.h"
#import "NSObject+MLNUIKVO.h"
#import "NSObject+MLNUIDealloctor.h"
#import "MLNUIExtScope.h"

#define kArrayPlaceHolder @"_array"

@interface MLNUIDataBinding() {
    pthread_mutex_t _lock;
}
@property (nonatomic, strong) NSMutableDictionary *dataMap;
@property (nonatomic, strong) NSMapTable *observerMap;
@property (nonatomic, strong) NSMapTable *observerIDsMap;
@property (nonatomic, strong) NSMutableArray *listViewTags;
@end

@implementation MLNUIDataBinding

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.dataMap = [NSMutableDictionary dictionary];
        self.observerMap =  [NSMapTable strongToStrongObjectsMapTable];
        self.observerIDsMap = [NSMapTable strongToWeakObjectsMapTable];
        self.listViewTags = [NSMutableArray array];
        LOCK_RECURSIVE_INIT();
        NSLog(@"%s",__FUNCTION__);
    }
    return self;
}

- (void)dealloc {
    NSLog(@"%s",__FUNCTION__);
}

#pragma mark - Public

- (void)bindData:(NSObject *)data forKey:(NSString *)key {
    NSParameterAssert(key);
    if (key) {
        LOCK();
        [self.dataMap setValue:data forKey:key];
        UNLOCK();
    }
}

- (NSArray<NSObject<MLNUIKVOObserverProtol> *> *)observersForKeyPath:(NSString *)keyPath forArray:(BOOL) forArray {
    NSParameterAssert(keyPath);
    if (!keyPath) {
        return nil;
    }
    if (forArray) {
        keyPath = [keyPath stringByAppendingString:kArrayPlaceHolder];
    }
    LOCK();
    NSMutableArray *observers = [self.observerMap objectForKey:keyPath];
    UNLOCK();
    return observers;
}

- (NSArray <NSObject<MLNUIKVOObserverProtol> *> *)dataObserversForKeyPath:(NSString *)keyPath {
    return [self observersForKeyPath:keyPath forArray:NO];
}

- (NSArray <NSObject<MLNUIKVOObserverProtol> *> *)arrayObserversForKeyPath:(NSString *)keyPath {
    return [self observersForKeyPath:keyPath forArray:YES];
}

- (NSString *)addMLNUIObserver:(NSObject<MLNUIKVOObserverProtol> *)observer forKeyPath:(NSString *)keyPath {
    NSParameterAssert(observer && keyPath);
    if (!observer || !keyPath) return nil;
    
    NSArray *keys = [keyPath componentsSeparatedByString:@"."];
    return [self addMLNUIObserver:observer forKeys:keys];
}

- (void)removeMLNUIObserver:(NSObject<MLNUIKVOObserverProtol> *)observer forKeyPath:(NSString *)keyPath {
    NSParameterAssert(observer && keyPath);
    if (!observer || !keyPath) return;
    
    NSArray *keys = [keyPath componentsSeparatedByString:@"."];
    [self removeMLNUIObserver:observer forKeys:keys];
}

- (void)removeMLNUIObserverByID:(NSString *)observerID {
    NSParameterAssert(observerID);
    if(!observerID) return;
    
    LOCK();
    id<MLNUIKVOObserverProtol> observer = [self.observerIDsMap objectForKey:observerID];
    UNLOCK();
    if (observer && [observer respondsToSelector:@selector(keyPath)]) {
        [self removeMLNUIObserver:observer forKeyPath:[observer keyPath]];
    }
}

#pragma mark - Array
- (void)bindArray:(NSArray *)array forKey:(NSString *)key {
    [self bindData:array forKey:key];
}

#pragma mark - Lua KeyPath
- (id)dataForKeyPath:(NSString *)keyPath {
    NSParameterAssert(keyPath);
    if(!keyPath) return nil;
    NSArray *keys = [keyPath componentsSeparatedByString:@"."];
    return [self dataForKeys:keys];
}

- (void)updateDataForKeyPath:(NSString *)keyPath value:(id)value {
    NSParameterAssert(keyPath);
    if(!keyPath) return;
    
    NSArray *keys = [keyPath componentsSeparatedByString:@"."];
    [self updateDataForKeys:keys value:value];
}

#pragma mark - Lua Keys

- (id __nullable)dataForKeys:(NSArray *)keys {
    NSParameterAssert(keys);
    
    NSArray *formatKeys = [self formatKeys:keys allowFirstKeyIsNumber:NO allowLastKeyIsNumber:YES];
    if(!formatKeys) return nil;
    
    return [self dataForKeysArray:formatKeys frontObject:NULL];
}

- (void)updateDataForKeys:(NSArray *)keys value:(id)value {
    NSParameterAssert(keys);
    
    keys = [self formatKeys:keys allowFirstKeyIsNumber:NO allowLastKeyIsNumber:YES];
    if(!keys) return;
    
    NSString *firstKey = keys.firstObject;
    NSString *lastKey = keys.lastObject;
    
    if (keys.count == 1) {
//        [self.dataMap setObject:value forKey:firstKey];
        @try {
            LOCK();
            [self.dataMap setValue:value forKeyPath:firstKey];
        } @catch (NSException *exception) {
            NSString *log = [NSString stringWithFormat:@"%@ %s",exception,__FUNCTION__];
            [self doErrorLog:log];
        } @finally {
            UNLOCK();
        }
        UNLOCK();
    } else {
        NSObject *frontObject;
        [self dataForKeysArray:keys frontObject:&frontObject];
        int index = 0;
        BOOL isNum = [self scanInt:&index forStringOrNumber:lastKey];
        BOOL isMArray = [frontObject isKindOfClass:[NSMutableArray class]];
        if (isNum != isMArray) {
            NSString *log = [NSString stringWithFormat:@"key: %@ and  value type: %@ are incompatible",lastKey, frontObject.class];
            [self doErrorLog:log];
            return;
        }
        @try {
            if (isMArray) {
                --index;
                NSMutableArray *arr = (NSMutableArray *)frontObject;
                if (index < 0 || index >= arr.count) {
                    NSString *log = [NSString stringWithFormat:@"index %d exceed range of array [1, %zd]",index+1,arr.count];
                    [self doErrorLog:log];
                    return;
                }
                value ? arr[index] = value : [arr removeObjectAtIndex:index];
            } else {
                [frontObject setValue:value forKeyPath:lastKey];
            }
        } @catch (NSException *exception) {
            NSString *log  = [NSString stringWithFormat:@"%@ %s",exception, __func__];
            [self doErrorLog:log];
        }
    }
}

- (NSString *)addMLNUIObserver:(NSObject<MLNUIKVOObserverProtol> *)observer forKeys:(NSArray *)keys {
    NSParameterAssert(observer && [keys isKindOfClass:[NSArray class]]);
    if(!observer || ![keys isKindOfClass:[NSArray class]] || keys.count == 0) return nil;
    keys = [self formatKeys:keys allowFirstKeyIsNumber:NO allowLastKeyIsNumber:NO];
    if(!keys) return nil;
    
//    NSString *obKey = [keys componentsJoinedByString:@"."];
    NSObject *frontObject;
    NSObject *object = [self dataForKeysArray:keys frontObject:&frontObject];
    NSString *path = keys.lastObject;
    NSString *uuid;
//    if (keys.count == 1) {
//        // TODO:监听dataMap.
//    }
    /*
     ['source']:array, object != nil ,frontObject = nil
     ['userData']:object, object != nil, frontObject = nil
     ['userData','name'], object = nil, frontObject != nil
     */
    if (![frontObject isKindOfClass:[NSArray class]]) {
        uuid = [self _realAddDataObserver:observer forObject:frontObject keys:keys path:path];
    }
    
    if ([object isKindOfClass:[NSMutableArray class]]) {
        NSString *uuid2 = [self _realAddArrayObserver:observer forObject:object keys:keys];
        uuid = uuid2 ? uuid2 : uuid;
    }
    return uuid;
}

- (void)removeMLNUIObserver:(NSObject<MLNUIKVOObserverProtol> *)observer forKeys:(NSArray *)keys {
    NSParameterAssert(observer && keys);
    if(!observer || ![keys isKindOfClass:[NSArray class]] || keys.count == 0) return;
    keys = [self formatKeys:keys allowFirstKeyIsNumber:NO allowLastKeyIsNumber:NO];
    if(!keys) return ;
    
    NSString *obKey = [keys componentsJoinedByString:@"."];
    NSObject *frontObject;
    NSObject *object = [self dataForKeysArray:keys frontObject:&frontObject];
    NSString *path = keys.lastObject;
//    if (keys.count == 1) {
//        //TODO:移除监听dataMap
//    }
    // frontObject not array, then path not number
    if (![frontObject isKindOfClass:[NSArray class]]) {
        [self _realRemoveDataObserver:observer forObject:frontObject obKey:obKey path:path];
    }
    if ([object isKindOfClass:[NSMutableArray class]]) {
        obKey = [obKey stringByAppendingString:kArrayPlaceHolder];
        [self _realRemoveArrayObserver:observer forObject:(NSMutableArray *)object obKey:obKey];
    }
}

- (void)addListViewTag:(NSString *)tag {
    if (tag) {
        [self.listViewTags addObject:tag];
    }
}

#pragma mark - Observer Private

- (NSString *)_realAddDataObserver:(NSObject<MLNUIKVOObserverProtol> *)observer forObject:(id)object keys:(NSArray *)keys  path:(NSString *)path {
    if (!object || !observer) return nil;
    NSString *uuid;
//    NSObject *object = [self _dataForKey:key path:nil];
    NSString *obKey = [keys componentsJoinedByString:@"."];
    LOCK();
    NSMutableArray *observerArray = [self.observerMap objectForKey:obKey];
    if (!observerArray) {
        observerArray = [NSMutableArray array];
        [self.observerMap setObject:observerArray forKey:obKey];
    }
    
    if ([observerArray containsObject:observer]) {
        NSLog(@"data oberver already exist for key %@",obKey);
        return nil;
    }
    
    @weakify(self);
    @weakify(observer);
    void(^obBlock)(NSString*,NSObject*,NSDictionary*) = ^(NSString *kp, NSObject *object, NSDictionary *change) {
        @strongify(self);
        @strongify(observer);
        if (self && observer) {
            [observer mlnui_observeValueForKeyPath:kp ofObject:object change:change];
        }
    };
    
    [observer mlnui_observeObject:object property:path withBlock:^(id  _Nonnull observer, id  _Nonnull object, id  _Nonnull oldValue, id  _Nonnull newValue, NSDictionary<NSKeyValueChangeKey,id> * _Nonnull change) {
        obBlock(path,object, change);
    }];
    
    [object mlnui_addDeallocationCallback:^(id  _Nonnull receiver) {
        @strongify(self);
        @strongify(observer);
        if (self && observer) {
            [self removeMLNUIObserver:observer forKeys:keys];
        }
    }];
    
    [observerArray addObject:observer];
    uuid = [[NSUUID UUID] UUIDString];
    [self.observerIDsMap setObject:observer forKey:uuid];
    
    UNLOCK();
    return uuid;
}

- (NSString *)_realAddArrayObserver:(NSObject<MLNUIKVOObserverProtol> *)observer forObject:(NSObject *)object keys:(NSArray *)keys {
    NSString *uuid;
//    NSObject *object = [self _dataForKey:key path:path];
    // 只有NSMutableArray才有必要添加observer
    if (![object isKindOfClass:[NSMutableArray class]]) {
        NSString *log = [NSString stringWithFormat:@"binded object %@, is not KindOf NSMutableArray",object.class];
        NSLog(@"%@",log);
        return nil;
    }
    NSString *obKey = [keys componentsJoinedByString:@"."];
    obKey = [obKey stringByAppendingString:kArrayPlaceHolder];
    LOCK();
    NSMutableArray *observerArray = [self.observerMap objectForKey:obKey];
    if (!observerArray) {
        observerArray = [NSMutableArray array];
        [self.observerMap setObject:observerArray forKey:obKey];
    }
    
    if ([observerArray containsObject:observer]) {
        NSLog(@"array observer already exist for key %@",obKey);
        return nil;
    }
    
    @weakify(self);
    @weakify(observer);
    void(^obBlock)(NSString*,NSObject*,NSDictionary*) = ^(NSString *kp, NSObject *object, NSDictionary *change) {
        @strongify(self);
        @strongify(observer);
        if (self && observer) {
            [observer mlnui_observeValueForKeyPath:kp ofObject:object change:change];
        }
    };
    
    NSMutableArray *bindArray = (NSMutableArray *)object;
//        [bindArray mlnui_startKVOIfMutable];
    [observer mlnui_observeArray:bindArray withBlock:^(id  _Nonnull observer, id  _Nonnull object, id  _Nonnull oldValue, id  _Nonnull newValue, NSDictionary<NSKeyValueChangeKey,id> * _Nonnull change) {
        obBlock(nil, object, change);
    }];
    
    if ([bindArray mlnui_is2D]) {
        @weakify(bindArray);
        [bindArray enumerateObjectsUsingBlock:^(NSMutableArray*  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if ([obj isKindOfClass:[NSMutableArray class]]) {
                [observer mlnui_observeArray:obj withBlock:^(id  _Nonnull observer, id  _Nonnull object, id  _Nonnull oldValue, id  _Nonnull newValue, NSDictionary<NSKeyValueChangeKey,id> * _Nonnull change) {
                    @strongify(bindArray);
                    NSMutableDictionary *newChange = change.mutableCopy;
                    [newChange setValue:bindArray forKey:MLNUIKVOOrigin2DArrayKey];
                    obBlock(nil, object, newChange);
                }];
                
                //自动移除监听
                [obj mlnui_addDeallocationCallback:^(id  _Nonnull receiver) {
                    [receiver mlnui_removeAllObservations];
                }];
            }
        }];
    }
    //自动移除监听
    [bindArray mlnui_addDeallocationCallback:^(id  _Nonnull receiver) {
        @strongify(self);
        @strongify(observer);
        if (self && observer) {
            [self removeMLNUIObserver:observer forKeys:keys];
        }
    }];
    
    [observerArray addObject:observer];
    uuid = [[NSUUID UUID] UUIDString];
    [self.observerIDsMap setObject:observer forKey:uuid];
    
    UNLOCK();
    return uuid;
}

- (void)_realRemoveDataObserver:(NSObject<MLNUIKVOObserverProtol> *)observer forObject:(NSObject *)object obKey:(NSString *)obKey path:(NSString *)path {
    if(!observer) return;
    
    if (obKey && observer) {
        LOCK();
        NSMutableArray *observers = [self.observerMap objectForKey:obKey];
        [observers removeObject:observer];
        UNLOCK();
    }
    
    if (path) {
        [object mlnui_removeObervationsForOwner:observer keyPath:path];
    }
}

- (void)_realRemoveArrayObserver:(NSObject<MLNUIKVOObserverProtol> *)observer forObject:(NSMutableArray *)object obKey:(NSString *)obKey {
    if(!observer) return;
    
    if (obKey) {
        LOCK();
        NSMutableArray *observers = [self.observerMap objectForKey:obKey];
        [observers removeObject:observer];
        UNLOCK();
    }
    
    if (![object isKindOfClass:[NSMutableArray class]]) {
        return;
    }
    [object mlnui_removeArrayObervationsForOwner:observer];

    if ([object mlnui_is2D]) { //处理二维数组
        @weakify(observer);
        [object enumerateObjectsUsingBlock:^(NSMutableArray *  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            @strongify(observer);
            if ([obj isKindOfClass:[NSMutableArray class]]) {
                [obj mlnui_removeArrayObervationsForOwner:observer];
            }
        }];
    }
}

#pragma mark - GetData Private
// keys=['userData.source'] -> frontObject = self.dataMap
- (id)dataForKeysArray:(NSArray *)keys frontObject:(NSObject **)frontObject {
    NSMutableString *frontKey = [[keys firstObject] mutableCopy];
    if(!frontKey) return nil;
    
    NSObject *obj;
    @try {
        LOCK();
        //    NSObject *obj = [self.dataMap objectForKey:firstKey];
        obj = [self.dataMap valueForKeyPath:frontKey];
        if(frontObject) *frontObject = self.dataMap;
    } @catch (NSException *exception) {
        NSString *log = [NSString stringWithFormat:@"%@ %s",exception,__FUNCTION__];
        [self doErrorLog:log];
    } @finally {
        UNLOCK();
    }
    BOOL isListViewDataSource = [self.listViewTags containsObject:frontKey];
    NSObject *res = obj;
    // 从第二个位置开始遍历
    for (int i = 1; i < keys.count; i++) {
        if (i == keys.count - 1 && frontObject) {
            *frontObject = res;
        }
        isListViewDataSource = [self.listViewTags containsObject:frontKey];
        
        NSString *k = keys[i];
        int index = 0;
        BOOL isNum = [self scanInt:&index forStringOrNumber:k];
        BOOL isArray = [res isKindOfClass:[NSArray class]];
        if (isNum != isArray) {
            if(frontObject) *frontObject = nil;
            NSString *log  = [NSString stringWithFormat:@"key %@ and  value %@ are incompatible",k,res.class];
            [self doErrorLog:log];
            return nil;
        }
        if (isArray) {
            if (isListViewDataSource && ![(NSArray *)res mlnui_is2D]) { //是list-source且不是二维数组
                if (i < keys.count - 1) {
                    NSString *nextKey = keys[i+1];
                    int tmp;
                    BOOL nextIsNum = [self scanInt:&tmp forStringOrNumber:nextKey]; //下一个是数字，说明这个是section，抛弃.
                    if (nextIsNum) {
                        if (index == 1) {
                            continue;
                        }
                        NSString *log = [NSString stringWithFormat:@"index %d illegal, should be 1",index];
                        [self doErrorLog:log];
                        return nil;
                    }
                }
            }
            --index; // lua索引
            if (index <  0 || index >= [(NSArray *)res count]) {
                if(frontObject) *frontObject = nil;
                NSString *log = [NSString  stringWithFormat:@"index %d illegal, should match range of array [1, %zd]",index+1,[(NSArray *)res count]];
                [self doErrorLog:log];
                return nil;
            }
            res = ((NSArray *)res)[index];
            [frontKey appendString:@"."];
            [frontKey appendString:@(index+1).stringValue]; //to lua索引
        } else {
            @try {
                [frontKey appendString:@"."];
                [frontKey appendString:k];
                res = [res valueForKeyPath:k];
            } @catch (NSException *exception) {
                if(frontObject) *frontObject = nil;
                NSString *log = [NSString stringWithFormat:@"%@ %s",exception,__FUNCTION__];
                [self doErrorLog:log];
                return nil;
            }
        }
    }
    return res;
}

#pragma mark - Utils
- (BOOL)scanInt:(int *)number forStringOrNumber:(NSString *)obj {
    if(!obj) return NO;
    
    //兼容key是string类型
    if ([obj isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:obj];
        return [scanner scanInt:number] && [scanner isAtEnd];
    }
    
    if ([obj isKindOfClass:[NSNumber class]]) {
        *number = [(NSNumber *)obj intValue];
        return YES;
    }
    return NO;
}

//[a,b,1,c,d] -> [a.b,1,c.d]
-(NSArray *)formatKeys:(NSArray *)keys allowFirstKeyIsNumber:(BOOL)allowFirstKeyIsNumber allowLastKeyIsNumber:(BOOL)allowLastKeyIsNumber {
    if (keys.count <= 1) {
        return keys;
    }
    NSString *first = keys.firstObject;
    if (!allowFirstKeyIsNumber && ![first isKindOfClass:[NSString class]]) {
        NSLog(@"first key must be string!");
        return nil;
    }
    NSString *last = keys.lastObject;
    if(!allowLastKeyIsNumber && ![last isKindOfClass:[NSString class]]){
        NSLog(@"last key must be string!");
        return nil;
    }
    NSMutableArray *formatKeys = [NSMutableArray array];
    NSMutableString *combineString;
    for (int i = 0; i < keys.count; i++) {
        int tmp;
        NSString *value = keys[i];
        BOOL isNum = [self scanInt:&tmp forStringOrNumber:value];
        if (isNum) {
            if (combineString) {
                [formatKeys addObject:combineString];
                combineString = nil;
            }
            [formatKeys addObject:@(tmp)];
        } else {
            if (!combineString) {
                combineString = [NSMutableString string];
            }
            if (combineString.length > 0) {
                [combineString appendString:@"."];
            }
            [combineString appendString:value];
        }
    }
    if (combineString.length > 0) {
        [formatKeys addObject:combineString];
    }
    return formatKeys;
}

- (void)doErrorLog:(NSString *)log{
    NSLog(@"%@",log);
    if(self.errorLog) self.errorLog(log);
}

/*
 - (id)_dataForKey:(NSString *)key path:(NSString *)path {
     if (!key) return nil;
     LOCK();
     NSObject *object = [self.dataMap objectForKey:key];
     UNLOCK();
     if (!path) {
         return object;
     }
     NSObject *res;
     @try {
         res = [object valueForKeyPath:path];
     } @catch (NSException *exception) {
         NSLog(@"exception: %s %@",__func__, exception);
     }
     return res;
 }
 
 - (NSString *)addDataObserver:(NSObject<MLNUIKVOObserverProtol> *)observer forKeyPath:(NSString *)keyPath {
 //    [self _realAddObserver:observer forKeyPath:keyPath isArray:NO];
     NSParameterAssert(observer && keyPath);
     if (!observer || !keyPath) return nil;
     
     NSString *key, *path;
     [self extractFirstKey:&key path:&path from:keyPath];
     if (!key || !path) {
         NSLog(@"key: %@ and path: %@ should not be nil",key,path);
         return nil;
     }
     NSObject *obj = [self _dataForKey:key path:nil];
     return [self _realAddDataObserver:observer forObject:obj obKey:keyPath path:path];
 }

 - (void)removeDataObserver:(NSObject<MLNUIKVOObserverProtol> *)observer forKeyPath:(NSString *)keyPath {
 //    [self _realRemoveObserver:observer forKeyPath:keyPath forArray:NO];
     NSParameterAssert(observer && keyPath);
     if(!observer || !keyPath) return;
     
     LOCK();
     NSMutableArray *observers = [self.observerMap objectForKey:keyPath];
     [observers removeObject:observer];
     UNLOCK();

     NSString *key, *path;
     [self extractFirstKey:&key path:&path from:keyPath];
     if (!key || !path) {
         NSLog(@"key: %@ and path: %@ should not be nil",key,path);
         return;
     }
     id obj = [self _dataForKey:key path:path];
     [obj mlnui_removeObervationsForOwner:observer keyPath:path];
 }
 
// eg: form="userdata.a.b" -> key = "userdata", path = "a.b"
- (void)extractFirstKey:(NSString **)firstKey path:(NSString **)path from:(NSString *)from {
    NSMutableArray *coms = [from componentsSeparatedByString:@"."].mutableCopy;
    *firstKey = coms.firstObject;
    if (coms.count >= 2 && ![[coms lastObject] isEqualToString:@""]) {
        [coms removeObjectAtIndex:0];
        *path = [coms componentsJoinedByString:@"."];
    }
}

 - (NSString *)addArrayObserver:(NSObject<MLNUIKVOObserverProtol> *)observer forKey:(NSString *)keyPath {
 //    [self _realAddObserver:observer forKeyPath:key isArray:YES];
     NSString *uuid;
     NSParameterAssert(observer && keyPath);
     if (!observer || !keyPath) return nil;
     
     NSString *key, *path;
     [self extractFirstKey:&key path:&path from:keyPath];
     if (key && path) {
         // add data observer
         NSObject *object = [self _dataForKey:key path:nil];
         uuid = [self _realAddDataObserver:observer forObject:object obKey:keyPath path:path];
     }
     NSObject *object = [self _dataForKey:key path:path];
     NSString *uuid2 = [self _realAddArrayObserver:observer forObject:object obKey:keyPath];
     return uuid2 ? uuid2 : uuid;
 }

 - (void)removeArrayObserver:(NSObject<MLNUIKVOObserverProtol> *)observer forKey:(NSString *)keyPath {
 //    [self _realRemoveObserver:observer forKeyPath:key forArray:YES];
     NSParameterAssert(observer && keyPath);
     if(!observer || !keyPath) return;
     
     LOCK();
     NSMutableArray *observers = [self.observerMap objectForKey:keyPath];
     [observers removeObject:observer];
     UNLOCK();

     NSString *key, *path;
     [self extractFirstKey:&key path:&path from:keyPath];
     if (key && path) {
         // remove data observer
 //        [self removeDataObserver:observer forKeyPath:keyPath];
         id obj = [self _dataForKey:key path:nil];
         [obj mlnui_removeObervationsForOwner:observer keyPath:path];
     }
     id obj = [self _dataForKey:key path:path];
     [obj mlnui_removeArrayObervationsForOwner:observer];
 }
 */

//- (void)_realAddObserver:(NSObject<MLNUIKVOObserverProtol> *)observer forKeyPath:(NSString *)keyPath isArray:(BOOL)isArray {
//    NSParameterAssert(observer && keyPath);
//    if (!observer || !keyPath) return;
//
//    NSString *key, *path;
//    if (!isArray) {
//        [self extractFirstKey:&key path:&path from:keyPath];
//        if (!key || !path) {
//            NSLog(@"key: %@ and path: %@ should not be nil",key,path);
//            return;
//        }
//    } else {
//        key = keyPath;
//    }
//
//    NSObject *object = [self dataForKeyPath:key];
//    // 只有NSMutableArray才有必要添加observer
//    if (isArray && ![object isKindOfClass:[NSMutableArray class]]) {
//        NSLog(@"binded object %@, is not KindOf NSMutableArray",object);
//        return;
//    }
//
//    LOCK();
//    NSMutableArray *observerArray = [self.observerMap objectForKey:keyPath];
//    if (!observerArray) {
//        observerArray = [NSMutableArray array];
//        [self.observerMap setObject:observerArray forKey:keyPath];
//    }
//
//    @weakify(self);
//    @weakify(observer);
//    void(^obBlock)(NSString*,NSObject*,NSDictionary*) = ^(NSString *kp, NSObject *object, NSDictionary *change) {
//        @strongify(self);
//        @strongify(observer);
//        if (self && observer) {
////            pthread_mutex_lock(&self->_lock);
////            NSArray *obsCopy = observerArray.copy;
////            pthread_mutex_unlock(&self->_lock);
////            for (NSObject<MLNUIKVOObserverProtol> *ob in obsCopy) {
////                [ob mlnui_observeValueForKeyPath:kp ofObject:object change:change];
////            }
//            [observer mlnui_observeValueForKeyPath:kp ofObject:object change:change];
//        }
//    };
//
//    if (!isArray) {
//        [observer mlnui_observeObject:object property:path withBlock:^(id  _Nonnull observer, id  _Nonnull object, id  _Nonnull oldValue, id  _Nonnull newValue, NSDictionary<NSKeyValueChangeKey,id> * _Nonnull change) {
//            obBlock(path,object, change);
//        }];
//    } else {
//        NSMutableArray *bindArray = (NSMutableArray *)object;
////        [bindArray mlnui_startKVOIfMutable];
//
//        [observer mlnui_observeArray:bindArray withBlock:^(id  _Nonnull observer, id  _Nonnull object, id  _Nonnull oldValue, id  _Nonnull newValue, NSDictionary<NSKeyValueChangeKey,id> * _Nonnull change) {
//            obBlock(nil, object, change);
//        }];
//
//        if ([bindArray mlnui_is2D]) {
//            [bindArray enumerateObjectsUsingBlock:^(NSMutableArray*  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
//                if ([obj isKindOfClass:[NSMutableArray class]]) {
//                    [observer mlnui_observeArray:obj withBlock:^(id  _Nonnull observer, id  _Nonnull object, id  _Nonnull oldValue, id  _Nonnull newValue, NSDictionary<NSKeyValueChangeKey,id> * _Nonnull change) {
//                        obBlock(nil, object, change);
//                    }];
//                }
//            }];
//        }
//    }
//
//    if (![observerArray containsObject:observer]) {
//        [observerArray addObject:observer];
//    }
//    UNLOCK();
//}

/*
- (void)_realRemoveObserver:(NSObject<MLNUIKVOObserverProtol> *)observer forKeyPath:(NSString *)keyPath forArray:(BOOL)forArray {
    NSParameterAssert(observer && keyPath);
    if(!observer || !keyPath) return;
    
    LOCK();
    NSMutableArray *observers = [self.observerMap objectForKey:keyPath];
    [observers removeObject:observer];
    UNLOCK();

    NSString *key, *path;
    if (!forArray) {
        [self extractFirstKey:&key path:&path from:keyPath];
        if (!key || !path) {
            NSLog(@"key: %@ and path: %@ should not be nil",key,path);
            return;
        }
    } else {
        key = keyPath;
    }

    if (key) {
        id obj = [self dataForKeyPath:key];
        if (forArray) {
            [obj mlnui_removeArrayObervationsForOwner:observer];
        } else {
            [obj mlnui_removeObervationsForOwner:observer keyPath:path];
        }
    }
}
 */

// ex:keyPath=userData.source, key=userData, path=source
//- (NSString *)_realAddDataObserver:(NSObject<MLNUIKVOObserverProtol> *)observer forKeyPath:(NSString *)keyPath key:(NSString *)key path:(NSString *)path {
//    NSString *uuid;
//    NSObject *object = [self _dataForKey:key path:nil];
//    LOCK();
//    NSMutableArray *observerArray = [self.observerMap objectForKey:keyPath];
//    if (!observerArray) {
//        observerArray = [NSMutableArray array];
//        [self.observerMap setObject:observerArray forKey:keyPath];
//    }
//
//    @weakify(self);
//    @weakify(observer);
//    void(^obBlock)(NSString*,NSObject*,NSDictionary*) = ^(NSString *kp, NSObject *object, NSDictionary *change) {
//        @strongify(self);
//        @strongify(observer);
//        if (self && observer) {
//            [observer mlnui_observeValueForKeyPath:kp ofObject:object change:change];
//        }
//    };
//
//    [observer mlnui_observeObject:object property:path withBlock:^(id  _Nonnull observer, id  _Nonnull object, id  _Nonnull oldValue, id  _Nonnull newValue, NSDictionary<NSKeyValueChangeKey,id> * _Nonnull change) {
//        obBlock(path,object, change);
//    }];
//
//    [object mlnui_addDeallocationCallback:^(id  _Nonnull receiver) {
//        @strongify(self);
//        @strongify(observer);
//        if (self && observer) {
//            [self removeMLNUIObserver:observer forKeyPath:keyPath];
//        }
//    }];
//
//    if (![observerArray containsObject:observer]) {
//        [observerArray addObject:observer];
//        uuid = [[NSUUID UUID] UUIDString];
//        [self.observerIDsMap setObject:observer forKey:uuid];
//    }
//    UNLOCK();
//    return uuid;
//}
@end
