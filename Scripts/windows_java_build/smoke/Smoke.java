import org.RDKit.*;

public class Smoke {
    public static void main(String[] args) {
        System.loadLibrary("GraphMolWrap");
        System.out.println("RDKit version: " + RDKFuncs.getRdkitVersion());
        RWMol m = RWMol.MolFromSmiles("CC(=O)Oc1ccccc1C(=O)O");
        System.out.println("Atoms: " + m.getNumAtoms());
        System.out.println("Canonical SMILES: " + m.MolToSmiles());
        System.out.println("MolWt: " + RDKFuncs.calcExactMW(m));
        ExplicitBitVect fp = RDKFuncs.getMorganFingerprintAsBitVect(m, 2, 2048);
        System.out.println("Morgan bits set: " + fp.getNumOnBits());
        RWMol q = RWMol.MolFromSmarts("c1ccccc1");
        System.out.println("Has benzene ring: " + m.hasSubstructMatch(q));
    }
}
