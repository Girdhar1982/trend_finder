import MetaTrader5 as mt5, datetime as dt, pandas as pd
mt5.initialize()
print(mt5.account_info()._asdict().get('server'), mt5.account_info()._asdict().get('login'))
d=mt5.history_deals_get(dt.datetime(2020,1,1), dt.datetime(2026,12,31))
print("deals:", None if d is None else len(d), mt5.last_error())
if d:
    df=pd.DataFrame([x._asdict() for x in d]); df['time']=pd.to_datetime(df.time,unit='s')
    df.to_pickle('my_deals.pkl')
    print(df.groupby('symbol').size().sort_values(ascending=False).head(8).to_string())
    print(df.type.value_counts().to_dict(), df.entry.value_counts().to_dict())
    print(df.time.min(), df.time.max())
    print(df.comment.value_counts().head(5).to_string())
