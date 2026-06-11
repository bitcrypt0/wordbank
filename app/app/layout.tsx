import type { Metadata } from "next";
import localFont from "next/font/local";
import { WalletProvider } from "@/lib/wallet/WalletProvider";
import { SiteHeader } from "@/components/SiteHeader";
import { SiteFooter } from "@/components/SiteFooter";
import "./globals.css";

/**
 * One strong typeface, like the collection: Fraunces (SIL OFL) is the exact
 * face embedded in every token's onchain SVG (assets/font/). The site sets
 * itself in the collection's own voice — see app/design/THEME.md.
 */
const fraunces = localFont({
  src: "./fonts/Fraunces-VF.ttf",
  weight: "100 900",
  variable: "--font-fraunces",
  display: "swap",
});

export const metadata: Metadata = {
  title: {
    default: "WORDBANK — ten thousand words, fully onchain",
    template: "%s · WORDBANK",
  },
  description:
    "10,000 word NFTs, each backed by 1,000 bound WORD tokens. A daily sentence game pays bounties, holders share swap fees, and a buy-and-burn shrinks WORD toward its living backing floor — all onchain.",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className={fraunces.variable}>
      <body>
        <WalletProvider>
          <SiteHeader />
          <main>{children}</main>
          <SiteFooter />
        </WalletProvider>
      </body>
    </html>
  );
}
