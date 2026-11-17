import org.RDKit.*;

public class InchiSmoke {
    public static void main(String[] args) {
        System.loadLibrary("GraphMolWrap");
        RWMol m = RWMol.MolFromSmiles("CC(=O)Oc1ccccc1C(=O)O");
        ExtraInchiReturnValues r = new ExtraInchiReturnValues();
        String inchi = RDKFuncs.MolToInchi(m, r);
        System.out.println("InChI:    " + inchi);
        System.out.println("InChIKey: " + RDKFuncs.InchiToInchiKey(inchi));
        ExtraInchiReturnValues r2 = new ExtraInchiReturnValues();
        ROMol back = RDKFuncs.InchiToMol(inchi, r2);
        System.out.println("Round trip SMILES: " + back.MolToSmiles());
    }
}
