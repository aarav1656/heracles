import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { WagmiProvider } from 'wagmi';
import { BrowserRouter, NavLink, Route, Routes } from 'react-router-dom';
import { BOOKS, PRICER_ADDRESS, TREATY_ADDRESS } from './abi';
import { explorer, wagmiConfig } from './chain';
import { Wallet } from './components/Wallet';
import { TxStatus } from './components/TxStatus';
import { Overview } from './pages/Overview';
import { Bind } from './pages/Bind';
import { Write } from './pages/Write';
import { QuotePage } from './pages/Quote';
import { Replay } from './pages/Replay';
import { SdkPage } from './pages/Sdk';
import { short } from './lib/format';

const queryClient = new QueryClient();

export function App() {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <BrowserRouter>
          <header className="top">
            <div className="wrap top-in">
              <NavLink to="/" className="mark" aria-label="Heracles, weekend gaps">Heracles</NavLink>
              <nav aria-label="Sections">
                <NavLink to="/" end>Weekend gaps</NavLink>
                <NavLink to="/quote">Quote</NavLink>
                <NavLink to="/replay">Replay</NavLink>
                <NavLink to="/bind">Price cover</NavLink>
                <NavLink to="/write">Earn premium</NavLink>
                <NavLink to="/sdk">SDK</NavLink>
              </nav>
              <Wallet />
            </div>
          </header>
          <main className="wrap">
            <Routes>
              <Route path="/" element={<Overview />} />
              <Route path="/quote" element={<QuotePage />} />
              <Route path="/replay" element={<Replay />} />
              <Route path="/bind" element={<Bind />} />
              <Route path="/write" element={<Write />} />
              <Route path="/sdk" element={<SdkPage />} />
            </Routes>
          </main>
          <footer className="wrap">
            <div className="foot">
            <p>Heracles: parametric cover for the weekend gap, for the LP vaults of stock perp exchanges. Arbitrum Sepolia, USDG and USDC books.</p>
            <p>
              Treaty <a href={explorer.address(TREATY_ADDRESS)} target="_blank" rel="noreferrer">{short(TREATY_ADDRESS)}</a>
              {' · '}Treaty's pricer <a href={explorer.address(PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(PRICER_ADDRESS)}</a>
              {' · '}{BOOKS[0].symbol} first loss <a href={explorer.address(BOOKS[0].firstLoss)} target="_blank" rel="noreferrer">{short(BOOKS[0].firstLoss)}</a>
              {' · '}{BOOKS[0].symbol} senior <a href={explorer.address(BOOKS[0].senior)} target="_blank" rel="noreferrer">{short(BOOKS[0].senior)}</a>
              {' · '}{BOOKS[1].symbol} first loss <a href={explorer.address(BOOKS[1].firstLoss)} target="_blank" rel="noreferrer">{short(BOOKS[1].firstLoss)}</a>
              {' · '}{BOOKS[1].symbol} senior <a href={explorer.address(BOOKS[1].senior)} target="_blank" rel="noreferrer">{short(BOOKS[1].senior)}</a>
            </p>
            </div>
          </footer>
          <TxStatus />
        </BrowserRouter>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
